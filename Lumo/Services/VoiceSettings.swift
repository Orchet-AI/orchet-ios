import Foundation

/// User preferences for the voice path. Persisted to UserDefaults.
///
/// `speakResponses` defaults to true so that as soon as the user uses
/// the voice path once, subsequent assistant replies are read aloud
/// automatically. The user can flip this off in Settings.
///
/// `hasUsedVoice` is set to true the first time
/// `VoiceComposerViewModel.consumeReadyTranscript()` returns a
/// non-nil transcript — i.e. the user actually completed a voice
/// turn. Settings reads it to decide whether to surface the Voice
/// section at all (kept hidden for first-time users).

enum VoiceSettings {
    private static let speakResponsesKey = "lumo.voice.speakResponses"
    private static let hasUsedVoiceKey = VoiceComposerViewModel.voiceUsageDefaultsKey
    private static let voiceIdKey = "lumo.voice.voiceId"
    /// IOS-HANDS-FREE-CONTINUOUS-1 — when true, the mic re-opens
    /// automatically after the agent finishes speaking (post-TTS
    /// tail-guard window) without the user tapping the mic again.
    /// Mirrors the web preference in `apps/web/components/VoiceMode.tsx`.
    private static let handsFreeContinuousKey = "lumo.voice.handsFreeContinuous"

    /// Default Deepgram Aura-2 voice (matches web's
    /// `apps/web/lib/voice-catalog.ts::DEFAULT_VOICE_ID`).
    /// Settings picker (Phase 4) toggles between this and
    /// `aura-2-orpheus-en`.
    static let defaultVoiceId = "aura-2-thalia-en"

    /// User's Deepgram voice id. Memory + UserDefaults only this
    /// lane; cross-device sync via Lumo Memory facts is filed as
    /// IOS-VOICE-PICKER-SYNC-1.
    static var voiceId: String {
        get {
            let stored = UserDefaults.standard.string(forKey: voiceIdKey)
            guard let stored, !stored.isEmpty else { return defaultVoiceId }
            return stored
        }
        set {
            UserDefaults.standard.set(newValue, forKey: voiceIdKey)
        }
    }

    static var speakResponses: Bool {
        get {
            // First-time default: true. When the toggle hasn't been
            // touched, UserDefaults returns false for `bool(forKey:)`,
            // so route through `object(forKey:)` to distinguish "not
            // set" from "explicitly off."
            if UserDefaults.standard.object(forKey: speakResponsesKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: speakResponsesKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: speakResponsesKey)
        }
    }

    static var hasUsedVoice: Bool {
        UserDefaults.standard.object(forKey: hasUsedVoiceKey) != nil
    }

    /// IOS-HANDS-FREE-CONTINUOUS-1 — opt-in hands-free auto-resume
    /// of the mic after each TTS turn. Default `false` so existing
    /// push-to-talk users aren't surprised by a mic that opens on
    /// its own. The streaming voice path (Daily WebRTC) keeps the
    /// mic open for the entire call regardless of this flag — this
    /// preference governs the legacy batch (Deepgram STT) path.
    static var handsFreeContinuous: Bool {
        get { UserDefaults.standard.bool(forKey: handsFreeContinuousKey) }
        set { UserDefaults.standard.set(newValue, forKey: handsFreeContinuousKey) }
    }
}
