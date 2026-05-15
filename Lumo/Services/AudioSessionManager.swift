import AVFoundation
import Foundation

/// Centralised AVAudioSession management for voice flows.
///
/// We use `.playAndRecord` so a single session covers both the user's
/// microphone capture and the assistant's TTS playback — switching
/// transparently between record and playback as the conversation
/// alternates. `.duckOthers` lowers other audio (Spotify, Apple
/// Music, podcast apps) while Lumo is speaking, then restores it.
///
/// The manager is a singleton because there's exactly one
/// AVAudioSession.sharedInstance() and racing two configurers across
/// the app would just toggle the route options against each other.
///
/// **Interruption + route change observers** (added in the one-mic
/// rollout): without these, an incoming phone call or a headphone
/// unplug while TTS was playing left the AVAudioEngine in a half-
/// alive state and the next `scheduleBuffer` could crash the audio
/// thread. The session now broadcasts the events as Combine
/// publishers so TTS sessions can cleanly cancel + tear down.

import Combine

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    /// Events emitted on AVAudioSession interruption / route change.
    /// Subscribers (DeepgramTTSSession) react by cancelling
    /// in-flight playback to avoid scheduling on a dead engine.
    enum SessionEvent {
        case interruptionBegan
        case interruptionEnded
        case routeChanged
    }

    let events = PassthroughSubject<SessionEvent, Never>()

    private let session: AVAudioSession
    private var configured = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        installObservers()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    /// Configure once before the first record/playback. Idempotent.
    func configureForVoiceConversation() throws {
        guard !configured else { return }
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true, options: [])
        configured = true
    }

    /// Tear down — used by tests and on explicit "exit voice mode."
    /// In normal use the session stays active for the app lifetime.
    func deactivate() {
        configured = false
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// True if the user has granted microphone permission. With
    /// Deepgram replacing the old recognizer, only microphone access
    /// is strictly needed; the separate speech-recognition permission
    /// has been removed.
    var hasMicrophonePermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Modern iOS 17+ permission API. Resolves false on denial.
    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: - System event observers

    private func installObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            switch type {
            case .began:
                // System has deactivated our session. Mark our
                // local cache so the next configure call re-runs.
                self.configured = false
                self.events.send(.interruptionBegan)
            case .ended:
                self.events.send(.interruptionEnded)
            @unknown default:
                break
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            self?.events.send(.routeChanged)
        }
    }
}
