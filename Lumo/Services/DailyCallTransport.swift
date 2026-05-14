import Daily
import Foundation

/// Live `StreamingVoiceTransport` adapter backed by Daily's
/// `CallClient`. The streaming voice service holds this behind the
/// `StreamingVoiceTransport` protocol so tests can swap in a mock.
///
/// Threading: `Daily.CallClient` is `@MainActor` end-to-end, and our
/// service publishes on the main actor as well. The delegate
/// callbacks land on the main thread; we forward them straight into
/// the closures supplied at `join`.
@MainActor
final class DailyCallTransport: NSObject, StreamingVoiceTransport, CallClientDelegate {
    private let client: CallClient
    private var onAppMessage: ((Data) -> Void)?
    private var onStateChange: ((StreamingVoiceState) -> Void)?

    override init() {
        self.client = CallClient()
        super.init()
        self.client.delegate = self
    }

    // MARK: - StreamingVoiceTransport

    func join(
        roomURL: String,
        clientToken: String,
        onAppMessage: @escaping (Data) -> Void,
        onStateChange: @escaping (StreamingVoiceState) -> Void
    ) async throws {
        guard let url = URL(string: roomURL) else {
            onStateChange(.error("invalid room url"))
            throw StreamingVoiceError.startFailed(status: -1)
        }
        self.onAppMessage = onAppMessage
        self.onStateChange = onStateChange
        onStateChange(.joining)

        do {
            let token: MeetingToken? = clientToken.isEmpty
                ? nil
                : MeetingToken(stringValue: clientToken)
            _ = try await client.join(url: url, token: token)
            onStateChange(.connected)
        } catch {
            onStateChange(.error("daily join: \(error.localizedDescription)"))
            throw error
        }
    }

    func sendAppMessage(_ payload: Data) async throws {
        try await client.sendAppMessage(json: payload, to: .all)
    }

    func leave() async {
        try? await client.leave()
        onStateChange?(.disconnected)
    }

    // MARK: - CallClientDelegate

    nonisolated func callClient(
        _ callClient: CallClient,
        appMessageAsJson jsonData: Data,
        from participantID: ParticipantID
    ) {
        // Hop to main so the rest of the service stays in-actor.
        Task { @MainActor in
            self.onAppMessage?(jsonData)
        }
    }

    nonisolated func callClient(
        _ callClient: CallClient,
        appMessageFromRestApiAsJson jsonData: Data
    ) {
        Task { @MainActor in
            self.onAppMessage?(jsonData)
        }
    }

    nonisolated func callClient(
        _ callClient: CallClient,
        callStateUpdated state: CallState
    ) {
        let mapped: StreamingVoiceState
        switch state {
        case .initialized: mapped = .idle
        case .joining: mapped = .joining
        case .joined: mapped = .connected
        case .leaving: mapped = .disconnected
        case .left: mapped = .disconnected
        }
        Task { @MainActor in
            self.onStateChange?(mapped)
        }
    }

    nonisolated func callClient(_ callClient: CallClient, error: CallClientError) {
        let description = String(describing: error)
        Task { @MainActor in
            self.onStateChange?(.error("daily error: \(description)"))
        }
    }
}
