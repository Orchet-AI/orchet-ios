import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Drives the Daily-WebRTC streaming voice path. Sister to
/// `VoiceComposerViewModel` (legacy batch push-to-talk); the chat
/// surface mounts whichever one matches `VoiceBackendConfig.current`.
///
/// Unlike the batch composer this view model does NOT collect a
/// transcript locally and hand it back to chat — the voice service
/// runs its own LLM and broadcasts back as Daily app-messages, which
/// `ChatViewModel.attachStreamingVoice(_:)` renders into the message
/// list. This view model only owns the call lifecycle and the
/// pending confirmation modal state.
@MainActor
final class StreamingVoiceViewModel: ObservableObject {
    enum UIState: Equatable {
        case idle
        case starting
        case connected
        case ending
        case error(String)
    }

    @Published private(set) var uiState: UIState = .idle
    /// When non-nil, the chat surface should mount the native
    /// confirmation modal. Cleared after the user resolves it.
    @Published var pendingConfirmation: VoiceShowConfirmationMessage?

    /// The underlying service — exposed so the parent view can
    /// `attachStreamingVoice(_:)` it to its chat view model.
    let service: StreamingVoiceService

    private let accessTokenProvider: () -> String?
    private var cancellables: Set<AnyCancellable> = []
    private let vad: NativeVADService = NativeVADService()

    init(
        service: StreamingVoiceService? = nil,
        accessTokenProvider: @escaping () -> String?
    ) {
        // Default service uses the live Daily transport. The
        // dependency injection is verbose because both the service's
        // and DailyCallTransport's initializers are @MainActor and
        // default arguments aren't allowed to evaluate inside the
        // main actor from a non-isolated context.
        let resolved = service ?? StreamingVoiceService(transport: DailyCallTransport())
        self.service = resolved
        self.accessTokenProvider = accessTokenProvider

        // Forward the service-level state into our UI state — keeps
        // the view binding terse and lets the view enum stay
        // intentionally smaller than the transport's full lifecycle.
        resolved.$state
            .sink { [weak self] new in self?.absorbServiceState(new) }
            .store(in: &cancellables)
        resolved.confirmation
            .sink { [weak self] msg in self?.pendingConfirmation = msg }
            .store(in: &cancellables)

        vad.onEvent = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                switch event {
                case .speechStarted:
                    await self.service.sendBargeIn(.speechStarted)
                case .speechEnded:
                    await self.service.sendBargeIn(.speechEnded)
                }
            }
        }
    }

    func start() async {
        guard uiState == .idle || isError else { return }
        uiState = .starting
        configureAudioSession()
        let jwt = accessTokenProvider() ?? ""
        do {
            _ = try await service.start(userJWT: jwt)
            // Successful start → onStateChange from the transport
            // will flip us to .connected via absorbServiceState.
            try? vad.start()
        } catch {
            uiState = .error(error.localizedDescription)
        }
    }

    func stop() async {
        guard uiState == .connected || uiState == .starting else { return }
        uiState = .ending
        vad.stop()
        await service.stop()
        uiState = .idle
        resetAudioSession()
    }

    /// User accepted or cancelled the pending confirmation. Posts to
    /// `/voice/confirm-action` and broadcasts a
    /// `confirmation_resolved` event over Daily so the voice service
    /// can continue speaking.
    func resolveConfirmation(_ confirmation: VoiceShowConfirmationMessage, accepted: Bool) async {
        guard let sessionID = service.currentSessionID else { return }
        let jwt = accessTokenProvider() ?? ""
        let url = VoiceBackendConfig.voiceServiceBaseURL.appendingPathComponent("voice/confirm-action")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !jwt.isEmpty {
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "session_id": sessionID,
            "confirmation_id": confirmation.confirmation_id,
            "accepted": accepted,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var continuation: String?
        var resultLabel: String = accepted ? "executed" : "cancelled"
        if let (data, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            struct Reply: Decodable {
                let result: String?
                let voice_continuation_hint: String?
            }
            if let parsed = try? JSONDecoder().decode(Reply.self, from: data) {
                resultLabel = parsed.result ?? resultLabel
                continuation = parsed.voice_continuation_hint
            }
        }

        let resolved = ConfirmationResolvedAppMessage(
            confirmation_id: confirmation.confirmation_id,
            accepted: accepted,
            result: .init(result: resultLabel, voice_continuation_hint: continuation)
        )
        await service.sendConfirmationResolved(resolved)
        pendingConfirmation = nil
    }

    // MARK: - Private

    private var isError: Bool {
        if case .error = uiState { return true }
        return false
    }

    private func absorbServiceState(_ new: StreamingVoiceState) {
        switch new {
        case .idle, .disconnected:
            if uiState != .idle { uiState = .idle }
        case .fetchingRoom, .joining:
            uiState = .starting
        case .connected:
            uiState = .connected
        case .error(let msg):
            uiState = .error(msg)
        }
    }

    private func configureAudioSession() {
        // .playAndRecord with .mixWithOthers so Spotify / Apple Music
        // continue to play under the call (mirrors the iPhone Phone
        // app's behavior on a low-volume call). `.allowBluetooth`
        // makes AirPods + car kits route audio correctly.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            // Audio session failure shouldn't crash the call; Daily
            // will surface its own error via the state stream.
        }
    }

    private func resetAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
