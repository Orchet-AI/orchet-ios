import XCTest
@testable import Lumo

/// Composer trailing-button state machine.
///
/// The button is now 6 modes (was 4) — mirrors the web `VoiceControlPanel`
/// (orchet-web PR #23) plus a send mode for non-empty composer text:
///
///   1. text empty + idle voice → `.idle`
///   2. text non-empty           → `.send`
///   3. listening                → `.listening` (was `.waveform`)
///   4. agent-speaking phase     → `.speaking`  (was `.agentSpeaking`)
///   5. agent-thinking phase OR  → `.thinking`
///      chat /turn streaming
///   6. voice error              → `.error`
///
/// Decision logic stays a pure static helper (`Mode.from`) so it's
/// directly testable without rendering the SwiftUI view.
///
/// Precedence (highest → lowest):
///   speaking > thinking > error > listening > send > idle
@MainActor
final class ChatComposerSwapTests: XCTestCase {

    // MARK: - 1. Empty input → idle

    func test_mode_emptyInput_isIdle() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(input: "", isListening: false),
            .idle
        )
    }

    func test_mode_whitespaceOnlyInput_isIdle() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(input: "   ", isListening: false),
            .idle
        )
    }

    // MARK: - 2. Non-empty input → send

    func test_mode_nonEmptyInput_isSend() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(input: "Plan a trip", isListening: false),
            .send
        )
    }

    func test_mode_singleCharacter_isSend() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(input: "h", isListening: false),
            .send
        )
    }

    // MARK: - 3. Send tap submits + clears text

    func test_send_clearsInputAfterSubmit() {
        let svc = ChatService(baseURL: URL(string: "http://localhost:0")!)
        let vm = ChatViewModel(service: svc)
        vm.input = "Plan a weekend trip to Vegas"
        XCTAssertFalse(vm.input.isEmpty, "precondition: input populated")

        vm.send(mode: .text)

        XCTAssertEqual(vm.input, "", "send must clear input — drives the icon swap back to idle/mic")
    }

    // MARK: - 4. Listening overrides input — listening wins

    func test_mode_listeningWithEmptyInput_isListening() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(input: "", isListening: true),
            .listening
        )
    }

    func test_mode_listeningWithPartialTranscript_staysListening() {
        // While listening, partial transcripts populate the text
        // field. The icon must NOT flicker to send during that
        // window.
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(input: "Plan a trip to", isListening: true),
            .listening,
            "listening always wins — partial transcripts shouldn't flip the icon to send"
        )
    }

    // MARK: - 5. Icon + accessibility metadata

    func test_modeIcons_matchSpec() {
        XCTAssertEqual(ChatComposerTrailingButton.Mode.idle.systemImage, "mic.fill")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.listening.systemImage, "waveform")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.send.systemImage, "paperplane.fill")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.speaking.systemImage, "speaker.wave.2.fill")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.error.systemImage, "exclamationmark.triangle.fill")
    }

    func test_modeAccessibilityIdentifiers_match() {
        XCTAssertEqual(ChatComposerTrailingButton.Mode.idle.accessibilityIdentifier, "chat.composer.mic")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.listening.accessibilityIdentifier, "chat.composer.listening")
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.send.accessibilityIdentifier, "chat.send",
            "send identifier must be preserved across the swap so existing chat.send accessibility tests keep working"
        )
        XCTAssertEqual(ChatComposerTrailingButton.Mode.speaking.accessibilityIdentifier, "chat.composer.bargeIn")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.error.accessibilityIdentifier, "chat.composer.error")
        XCTAssertEqual(ChatComposerTrailingButton.Mode.thinking.accessibilityIdentifier, "chat.composer.thinking")
    }

    // MARK: - 6. AGENT_SPEAKING / POST_SPEAKING_GUARD → speaking (barge-in)

    func test_mode_agentSpeakingPhase_overridesEverything() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: false, phase: .agentSpeaking
            ),
            .speaking
        )
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "Plan a trip", isListening: false, phase: .agentSpeaking
            ),
            .speaking,
            "phase must override input — Send hiding the barge-in is the bug class we're patching"
        )
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: true, phase: .agentSpeaking
            ),
            .speaking
        )
    }

    func test_mode_postSpeakingGuard_alsoSurfacesSpeaking_noFlicker() {
        // The 300 ms tail guard window MUST visually look the same
        // as AGENT_SPEAKING — flicker over 300 ms is ugly.
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: false, phase: .postSpeakingGuard
            ),
            .speaking
        )
    }

    func test_mode_listeningPhase_fallsThroughToInputBasedRules() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: false, phase: .listening
            ),
            .idle
        )
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "Plan a trip", isListening: false, phase: .listening
            ),
            .send
        )
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: true, phase: .listening
            ),
            .listening
        )
    }

    func test_mode_agentThinkingPhase_isThinking() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: false, phase: .agentThinking
            ),
            .thinking
        )
    }

    func test_mode_isThinkingFlag_isThinking() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: false, isThinking: true
            ),
            .thinking
        )
    }

    func test_mode_voiceError_isError() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "", isListening: false, isVoiceError: true
            ),
            .error
        )
    }

    func test_mode_speakingDominatesAllOtherSignals() {
        // Even with thinking + error + listening flags, speaking
        // wins — the user must always be able to barge in.
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.from(
                input: "anything",
                isListening: true,
                phase: .agentSpeaking,
                isVoiceError: true,
                isThinking: true
            ),
            .speaking
        )
    }

    func test_speakingMode_iconAndIdentifierAndLabel() {
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.speaking.systemImage,
            "speaker.wave.2.fill"
        )
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.speaking.accessibilityIdentifier,
            "chat.composer.bargeIn"
        )
        XCTAssertEqual(
            ChatComposerTrailingButton.Mode.speaking.accessibilityLabel,
            "Speaking — tap to interrupt"
        )
    }

    func test_modeTapActions_matchVisibleAffordance() {
        XCTAssertEqual(ChatComposerTrailingButton.Mode.idle.tapAction, .startVoice)
        XCTAssertEqual(ChatComposerTrailingButton.Mode.listening.tapAction, .stopVoice)
        XCTAssertEqual(ChatComposerTrailingButton.Mode.send.tapAction, .sendMessage)
        XCTAssertEqual(ChatComposerTrailingButton.Mode.speaking.tapAction, .stopSpeaking)
        XCTAssertEqual(ChatComposerTrailingButton.Mode.error.tapAction, .retryVoice)
        XCTAssertEqual(ChatComposerTrailingButton.Mode.thinking.tapAction, .noop)
    }

    func test_thinkingMode_blocksTap_andRejectsLongPress() {
        XCTAssertTrue(ChatComposerTrailingButton.Mode.thinking.blocksTap)
        XCTAssertFalse(ChatComposerTrailingButton.Mode.thinking.allowsLongPressPTT)
    }

    func test_idleMode_isTheOnlyLongPressPTTMode() {
        XCTAssertTrue(ChatComposerTrailingButton.Mode.idle.allowsLongPressPTT)
        XCTAssertFalse(ChatComposerTrailingButton.Mode.listening.allowsLongPressPTT)
        XCTAssertFalse(ChatComposerTrailingButton.Mode.send.allowsLongPressPTT)
        XCTAssertFalse(ChatComposerTrailingButton.Mode.speaking.allowsLongPressPTT)
        XCTAssertFalse(ChatComposerTrailingButton.Mode.error.allowsLongPressPTT)
    }

    // MARK: - 7. Barge-in handler

    func test_requestBargeIn_callsTtsCancel() async {
        let speech = SpeechRecognitionStub()
        let tts = TextToSpeechStub()
        let vm = VoiceComposerViewModel(speech: speech, tailGuardMs: 50)
        vm.observe(tts: tts)

        tts.state = .speaking(provider: .deepgram)
        try? await Task.sleep(nanoseconds: 50_000_000)

        vm.requestBargeIn()

        // The stub's cancel() resets state to .idle — observable
        // proof that requestBargeIn() reached tts.cancel().
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            tts.state, .idle,
            "requestBargeIn must call tts.cancel() so the .idle state propagates and clears the gate"
        )
    }

    func test_requestBargeIn_clearsGateImmediately() async {
        let speech = SpeechRecognitionStub()
        let tts = TextToSpeechStub()
        let vm = VoiceComposerViewModel(speech: speech, tailGuardMs: 1_000)
        vm.observe(tts: tts)

        tts.state = .speaking(provider: .deepgram)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.phase, .agentSpeaking, "precondition: TTS gate is held")

        vm.requestBargeIn()

        XCTAssertEqual(
            vm.phase,
            .listening,
            "Stop must clear the gate synchronously so the next tap-to-talk is not blocked"
        )
    }
}
