import Combine
import XCTest
@testable import Lumo

/// Drives StreamingVoiceService.handleInbound directly with synthetic
/// JSON payloads to assert the data-channel → Combine subject
/// routing. The real Daily transport is bypassed via the default
/// UnimplementedStreamingVoiceTransport — we're only validating the
/// decoder + subject fanout here. Subjects are subscribed via
/// PassthroughSubject's sink to confirm emission ordering.
@MainActor
final class StreamingVoiceServiceRoutingTests: XCTestCase {
    private var service: StreamingVoiceService!
    private var bag: Set<AnyCancellable>!

    override func setUp() async throws {
        try await super.setUp()
        service = StreamingVoiceService()
        bag = []
    }

    override func tearDown() async throws {
        bag = nil
        service = nil
        try await super.tearDown()
    }

    func test_handleInbound_userTranscript_routesToUserSubject() throws {
        let exp = expectation(description: "user transcript subject")
        var received: VoiceUserTranscriptMessage?
        service.userTranscript
            .sink { msg in received = msg; exp.fulfill() }
            .store(in: &bag)

        let raw = #"""
        {
          "type": "voice_user_transcript",
          "voice_session_id": "vs_1",
          "turn_id": "t_1",
          "text": "hello orchet"
        }
        """#
        service.handleInbound(Data(raw.utf8))
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(received?.text, "hello orchet")
        XCTAssertEqual(received?.voice_session_id, "vs_1")
        XCTAssertEqual(received?.turn_id, "t_1")
    }

    func test_handleInbound_assistantDeltaThenFinal_routeIndependently() {
        let deltaExp = expectation(description: "delta")
        let finalExp = expectation(description: "final")

        service.assistantTranscriptDelta
            .sink { _ in deltaExp.fulfill() }
            .store(in: &bag)
        service.assistantTranscriptFinal
            .sink { _ in finalExp.fulfill() }
            .store(in: &bag)

        let delta = #"""
        {"type":"voice_assistant_transcript_delta","voice_session_id":"vs_1","turn_id":"t_1","text":"Hi "}
        """#
        let finalMsg = #"""
        {"type":"voice_assistant_transcript_final","voice_session_id":"vs_1","turn_id":"t_1","text":"Hi there!"}
        """#
        service.handleInbound(Data(delta.utf8))
        service.handleInbound(Data(finalMsg.utf8))

        wait(for: [deltaExp, finalExp], timeout: 1)
    }

    func test_handleInbound_showConfirmation_routesToConfirmationSubject() {
        let exp = expectation(description: "confirmation")
        var received: VoiceShowConfirmationMessage?
        service.confirmation
            .sink { msg in received = msg; exp.fulfill() }
            .store(in: &bag)

        let raw = #"""
        {
          "type": "voice_show_confirmation",
          "voice_session_id": "vs_1",
          "confirmation_id": "c_42",
          "title": "Book this flight?",
          "summary": "BLR → BOM at 9:40am",
          "details": [{"label":"Price","value":"₹4,200"}],
          "expires_at": "2026-05-14T08:00:00Z"
        }
        """#
        service.handleInbound(Data(raw.utf8))
        wait(for: [exp], timeout: 1)

        XCTAssertEqual(received?.confirmation_id, "c_42")
        XCTAssertEqual(received?.title, "Book this flight?")
        XCTAssertEqual(received?.details?.first?.value, "₹4,200")
    }

    func test_handleInbound_unknownType_isDroppedSilently() {
        // No subject should emit; we wait briefly and assert no
        // crash plus no subject fire.
        var fired = false
        service.userTranscript.sink { _ in fired = true }.store(in: &bag)
        service.assistantTranscriptDelta.sink { _ in fired = true }.store(in: &bag)
        service.confirmation.sink { _ in fired = true }.store(in: &bag)

        let raw = #"""
        {"type":"voice_unknown_kind","payload":{"foo":42}}
        """#
        service.handleInbound(Data(raw.utf8))
        XCTAssertFalse(fired)
    }

    func test_handleInbound_malformedJson_isDroppedSilently() {
        var fired = false
        service.userTranscript.sink { _ in fired = true }.store(in: &bag)
        service.handleInbound(Data("{not-json".utf8))
        XCTAssertFalse(fired)
    }

    func test_handleInbound_marketplaceInstalled_routesToToastSubject() {
        let exp = expectation(description: "installed")
        var received: VoiceMarketplaceInstalledMessage?
        service.marketplaceInstalled
            .sink { msg in received = msg; exp.fulfill() }
            .store(in: &bag)

        let raw = #"""
        {"type":"voice_marketplace_installed","agent_id":"lumo-flights","display_name":"Lumo Flights"}
        """#
        service.handleInbound(Data(raw.utf8))
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(received?.agent_id, "lumo-flights")
    }
}
