import XCTest
@testable import Lumo

/// IOS-HANDS-FREE-CONTINUOUS-1 — verifies the auto-resume gate
/// in `VoiceComposerViewModel.attemptHandsFreeAutoResume()`.
///
/// The gate has five conditions:
///   - autoListenUnlocked (hasUsedVoice)
///   - handsFree toggle ON
///   - !userStoppedListening (no explicit Stop)
///   - !busy + enabled
///   - !micPausedForTts
///
/// Tests drive the TTS state machine (speaking → finished → tail guard
/// → listening) and assert whether `ensureAndStart` fired on the
/// speech stub by checking that `startCalls` incremented.
@MainActor
final class HandsFreeContinuousTests: XCTestCase {

    private struct DefaultsScope {
        let handsFreeKey = "lumo.voice.handsFreeContinuous"
        let lastUsedKey = "lumo.voice.lastUsedAt"

        func enableAutoListenUnlocked() {
            UserDefaults.standard.set(Date().timeIntervalSinceReferenceDate, forKey: lastUsedKey)
        }
        func clearAutoListenUnlocked() {
            UserDefaults.standard.removeObject(forKey: lastUsedKey)
        }
        func setHandsFree(_ on: Bool) {
            UserDefaults.standard.set(on, forKey: handsFreeKey)
        }
        func clear() {
            UserDefaults.standard.removeObject(forKey: handsFreeKey)
            UserDefaults.standard.removeObject(forKey: lastUsedKey)
        }
    }

    private let defaults = DefaultsScope()

    override func setUp() async throws {
        try await super.setUp()
        defaults.clear()
    }

    override func tearDown() async throws {
        defaults.clear()
        try await super.tearDown()
    }

    private func makeVM(tailGuardMs: Int = 30) -> (VoiceComposerViewModel, SpeechRecognitionStub, TextToSpeechStub) {
        let speech = SpeechRecognitionStub()
        let tts = TextToSpeechStub()
        let vm = VoiceComposerViewModel(speech: speech, tailGuardMs: tailGuardMs)
        vm.observe(tts: tts)
        return (vm, speech, tts)
    }

    private func waitForPhase(
        _ vm: VoiceComposerViewModel,
        _ expected: VoiceModeMachinePhase,
        timeout: TimeInterval = 1.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vm.phase == expected { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func driveSpeakingThenFinish(_ tts: TextToSpeechStub, vm: VoiceComposerViewModel) async {
        tts.state = .speaking(provider: .deepgram)
        await waitForPhase(vm, .agentSpeaking)
        tts.state = .finished(provider: .deepgram)
        await waitForPhase(vm, .postSpeakingGuard)
        await waitForPhase(vm, .listening, timeout: 1.0)
    }

    // MARK: - default OFF

    func test_handsFree_default_isOff_noAutoResume() async {
        defaults.enableAutoListenUnlocked()
        // toggle never written → returns false from UserDefaults
        let (vm, speech, tts) = makeVM()

        await driveSpeakingThenFinish(tts, vm: vm)

        // Allow one extra runloop tick for any Task hops.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(speech.startCalls, 0, "auto-resume must not fire with toggle off")
    }

    // MARK: - toggle ON + autoListenUnlocked → auto-resume fires

    func test_handsFree_on_unlocked_firesAutoResume() async {
        defaults.enableAutoListenUnlocked()
        defaults.setHandsFree(true)
        let (vm, speech, tts) = makeVM()

        await driveSpeakingThenFinish(tts, vm: vm)
        // Let the auto-resume Task hop complete.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(speech.startCalls, 1, "auto-resume should fire when all gates pass")
    }

    // MARK: - cold launch — autoListenUnlocked false suppresses

    func test_handsFree_on_butColdLaunch_noAutoResume() async {
        defaults.clearAutoListenUnlocked()
        defaults.setHandsFree(true)
        let (vm, speech, tts) = makeVM()

        await driveSpeakingThenFinish(tts, vm: vm)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(speech.startCalls, 0, "auto-resume must not fire on cold launch")
    }

    // MARK: - userStoppedListening suppresses

    func test_handsFree_userStoppedListening_suppressesAutoResume() async {
        defaults.enableAutoListenUnlocked()
        defaults.setHandsFree(true)
        let (vm, speech, tts) = makeVM()

        // Simulate the user starting then releasing a listening session.
        // pressBegan sets userStoppedListening = false; release after
        // hitting .listening sets it true. We can't drive .listening
        // directly without speech events, so use the public API:
        // tapToTalk → ensureAndStart → state goes via stub events.
        // Easier: emit a listening event from the stub then call release.
        await vm.tapToTalk()
        // Stub doesn't auto-emit .listening; nudge state manually via
        // SpeechRecognitionStub's continuation.
        speech.emitPartial("")
        try? await Task.sleep(nanoseconds: 50_000_000)
        vm.release()
        let priorStartCalls = speech.startCalls

        await driveSpeakingThenFinish(tts, vm: vm)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            speech.startCalls,
            priorStartCalls,
            "user-stopped flag should suppress auto-resume until next explicit tap"
        )
    }

    // MARK: - new tapToTalk clears the user-stop flag

    func test_handsFree_tapAfterUserStop_clearsFlag_andNextTtsAutoResumes() async {
        defaults.enableAutoListenUnlocked()
        defaults.setHandsFree(true)
        let (vm, speech, tts) = makeVM()

        // Stop, then tap-to-talk again to clear the flag.
        await vm.tapToTalk()
        speech.emitPartial("")
        try? await Task.sleep(nanoseconds: 50_000_000)
        vm.release()
        await vm.tapToTalk()
        let priorStartCalls = speech.startCalls

        await driveSpeakingThenFinish(tts, vm: vm)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            speech.startCalls,
            priorStartCalls + 1,
            "second tap-to-talk should clear stop flag; auto-resume should fire next TTS"
        )
    }
}
