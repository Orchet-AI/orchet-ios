import XCTest
@testable import Lumo

/// ORCHET-IOS-PARITY-1 — verify the chat view model renders user +
/// assistant bubbles inline from voice transcript app-messages
/// without re-dispatching the user transcript through chat /turn.
@MainActor
final class ChatViewModelStreamingTranscriptTests: XCTestCase {

    private func makeVM() -> ChatViewModel {
        // ChatService and its dependencies aren't exercised here; the
        // tests only call streaming-voice attachment paths which
        // mutate `messages` directly. A throwaway service satisfies
        // the initializer.
        let throwaway = ChatService(baseURL: URL(string: "http://localhost")!)
        return ChatViewModel(service: throwaway)
    }

    func test_attach_userTranscript_appendsUserBubble_noNetworkDispatch() {
        let vm = makeVM()
        let voice = StreamingVoiceService()
        vm.attachStreamingVoice(voice)

        voice.userTranscript.send(
            VoiceUserTranscriptMessage(
                type: "voice_user_transcript",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "what time is it in Tokyo?"
            )
        )

        // Bubble must show up without entering the streaming flow.
        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.role, .user)
        XCTAssertEqual(vm.messages.first?.text, "what time is it in Tokyo?")
        XCTAssertFalse(vm.isStreaming, "voice transcript must NOT trigger chat /turn streaming")
    }

    func test_attach_assistantDeltas_concatToSameBubble_finalReconciles() {
        let vm = makeVM()
        let voice = StreamingVoiceService()
        vm.attachStreamingVoice(voice)

        let deltas: [(String, String)] = [
            ("Hi ", "t_1"),
            ("there", "t_1"),
            ("!", "t_1"),
        ]
        for (chunk, turn) in deltas {
            voice.assistantTranscriptDelta.send(
                VoiceAssistantTranscriptDeltaMessage(
                    type: "voice_assistant_transcript_delta",
                    voice_session_id: "vs_1",
                    turn_id: turn,
                    text: chunk
                )
            )
        }

        // Exactly one in-flight assistant message exists, with the
        // concatenated text.
        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.text, "Hi there!")
        XCTAssertEqual(assistantMessages.first?.status, .streaming)

        // Final reconciles the text and marks delivered.
        voice.assistantTranscriptFinal.send(
            VoiceAssistantTranscriptFinalMessage(
                type: "voice_assistant_transcript_final",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "Hi there! It's 7:42 PM in Tokyo."
            )
        )

        let finalMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(finalMessages.count, 1)
        XCTAssertEqual(finalMessages.first?.text, "Hi there! It's 7:42 PM in Tokyo.")
        XCTAssertEqual(finalMessages.first?.status, .delivered)
    }

    func test_attach_finalWithoutDeltas_synthesizesAssistantBubble() {
        let vm = makeVM()
        let voice = StreamingVoiceService()
        vm.attachStreamingVoice(voice)

        voice.assistantTranscriptFinal.send(
            VoiceAssistantTranscriptFinalMessage(
                type: "voice_assistant_transcript_final",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "Sure — what city?"
            )
        )

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.text, "Sure — what city?")
        XCTAssertEqual(assistantMessages.first?.status, .delivered)
    }

    func test_attach_newTurn_startsFreshInflightBubble() {
        let vm = makeVM()
        let voice = StreamingVoiceService()
        vm.attachStreamingVoice(voice)

        // Turn 1 delta + final.
        voice.assistantTranscriptDelta.send(
            VoiceAssistantTranscriptDeltaMessage(
                type: "voice_assistant_transcript_delta",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "ok"
            )
        )
        voice.assistantTranscriptFinal.send(
            VoiceAssistantTranscriptFinalMessage(
                type: "voice_assistant_transcript_final",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "ok done"
            )
        )

        // Turn 2 delta — must NOT mutate turn 1's bubble.
        voice.assistantTranscriptDelta.send(
            VoiceAssistantTranscriptDeltaMessage(
                type: "voice_assistant_transcript_delta",
                voice_session_id: "vs_1",
                turn_id: "t_2",
                text: "next"
            )
        )

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertEqual(assistantMessages[0].text, "ok done")
        XCTAssertEqual(assistantMessages[0].status, .delivered)
        XCTAssertEqual(assistantMessages[1].text, "next")
        XCTAssertEqual(assistantMessages[1].status, .streaming)
    }

    func test_detach_marksInflightAsDelivered() {
        let vm = makeVM()
        let voice = StreamingVoiceService()
        vm.attachStreamingVoice(voice)

        voice.assistantTranscriptDelta.send(
            VoiceAssistantTranscriptDeltaMessage(
                type: "voice_assistant_transcript_delta",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "partial"
            )
        )
        vm.detachStreamingVoice()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertEqual(assistantMessages.first?.status, .delivered)
    }

    func test_reattach_clearsPriorInflightTracking() {
        let vm = makeVM()
        let voiceA = StreamingVoiceService()
        vm.attachStreamingVoice(voiceA)

        voiceA.assistantTranscriptDelta.send(
            VoiceAssistantTranscriptDeltaMessage(
                type: "voice_assistant_transcript_delta",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "first"
            )
        )

        let voiceB = StreamingVoiceService()
        vm.attachStreamingVoice(voiceB)

        // A delta on voiceA (old service) must no longer mutate the
        // chat — subscriptions were torn down. (The orphan inflight
        // bubble itself is harmless; what we're checking is that the
        // re-attach didn't leak a subscription.)
        voiceA.assistantTranscriptDelta.send(
            VoiceAssistantTranscriptDeltaMessage(
                type: "voice_assistant_transcript_delta",
                voice_session_id: "vs_1",
                turn_id: "t_1",
                text: "leaked"
            )
        )

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1)
        XCTAssertFalse(assistantMessages.first?.text.contains("leaked") ?? true)
    }
}
