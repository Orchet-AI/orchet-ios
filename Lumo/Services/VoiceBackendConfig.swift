import Foundation

/// Selects which voice pipeline the app mounts at the voice-button
/// entry-point. Read once at launch from `Info.plist` (key
/// `OrchetVoiceMode`), backed by the `ORCHET_VOICE_MODE` xcconfig
/// var.
///
/// - `.batch` (default): legacy push-to-talk path — `SpeechRecognitionService`
///   + `DeepgramTokenService` + `TextToSpeechService`. Audio flows
///   HTTP-batch through the gateway `/stt` and `/tts` routes.
/// - `.streaming`: Daily WebRTC against the orchet-voice Fly service.
///   Voice runs its own LLM, returns audio over the data channel, and
///   the iOS shell only renders inline transcript bubbles + native
///   confirmation modals. See ORCHET-IOS-PARITY-1.
///
/// Production xcconfig stays on `batch` until TestFlight soak
/// completes. Per-engineer override lives in `Lumo.local.xcconfig`.
enum LumoVoiceBackend: String {
    case streaming
    case batch
}

enum VoiceBackendConfig {
    /// Effective mode for the running process. Read once at launch —
    /// flipping the xcconfig requires a rebuild.
    static let current: LumoVoiceBackend = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "OrchetVoiceMode") as? String) ?? ""
        return LumoVoiceBackend(rawValue: raw.lowercased()) ?? .batch
    }()

    /// Base URL of the streaming voice service. Falls back to the
    /// production Fly host if the Info.plist value is missing — that
    /// keeps fresh-clone builds reaching a working backend, mirroring
    /// the `OrchetGatewayBase` fallback shape in `AppConfig`.
    static var voiceServiceBaseURL: URL {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "OrchetVoiceBase") as? String) ?? ""
        if !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        return URL(string: "https://orchet-voice.fly.dev")!
    }
}
