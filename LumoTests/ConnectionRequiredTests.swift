import XCTest
@testable import Lumo

/// PARITY-1D — tests the SSE decoder + ChatViewModel attach + the
/// auto-retry dedup on the inline-connect surface.
@MainActor
final class ConnectionRequiredTests: XCTestCase {

    // MARK: - SSE decoder

    func test_parseFrame_connectionRequired_decodesAndAttaches() throws {
        let line = #"data: {"type":"connection_required","value":{"agent_id":"google","display_name":"Google","authorize_url":"https://api.orchet.ai/connections/google/authorize?state=abc&code_challenge=xyz","blocked_tool":"gmail_search"}}"#
        let event = ChatService.parseFrame(line: line)
        guard case .connectionRequired(let value) = event else {
            XCTFail("expected .connectionRequired, got \(String(describing: event))")
            return
        }
        XCTAssertEqual(value.agent_id, "google")
        XCTAssertEqual(value.display_name, "Google")
        XCTAssertEqual(value.blocked_tool, "gmail_search")
        XCTAssertTrue(value.authorize_url.starts(with: "https://"))
        XCTAssertTrue(value.isRenderable)
    }

    func test_parseFrame_connectionRequired_dropsNonHttpsURL() {
        // Hard guard against schema drift — a relative URL or non-
        // https scheme must NOT render. Falls through to .other so
        // the chat surface keeps working.
        let line = #"data: {"type":"connection_required","value":{"agent_id":"x","display_name":"X","authorize_url":"javascript:alert(1)","blocked_tool":"foo"}}"#
        let event = ChatService.parseFrame(line: line)
        if case .connectionRequired = event {
            XCTFail("non-https authorize_url must NOT render as a connection card")
        }
    }

    func test_parseFrame_connectionRequired_dropsMissingFields() {
        let line = #"data: {"type":"connection_required","value":{"agent_id":"","display_name":"","authorize_url":"https://x","blocked_tool":""}}"#
        let event = ChatService.parseFrame(line: line)
        if case .connectionRequired = event {
            XCTFail("missing fields must not render — guard the chat surface")
        }
    }

    // MARK: - isRenderable shape guard

    func test_isRenderable_locksThePrivacyBoundary() {
        // Valid case
        XCTAssertTrue(
            ConnectionRequiredFrameValue(
                agent_id: "google",
                display_name: "Google",
                authorize_url: "https://example.com/oauth",
                blocked_tool: "gmail_search"
            ).isRenderable
        )
        // Invalid: empty fields
        XCTAssertFalse(
            ConnectionRequiredFrameValue(
                agent_id: "",
                display_name: "Google",
                authorize_url: "https://example.com/oauth",
                blocked_tool: "x"
            ).isRenderable
        )
        // Invalid: non-https scheme
        XCTAssertFalse(
            ConnectionRequiredFrameValue(
                agent_id: "google",
                display_name: "Google",
                authorize_url: "ftp://example.com/oauth",
                blocked_tool: "x"
            ).isRenderable
        )
    }

    // MARK: - ChatViewModel auto-retry dedup

    private func makeVM() -> ChatViewModel {
        let svc = ChatService(baseURL: URL(string: "http://localhost:0")!)
        return ChatViewModel(service: svc)
    }

    func test_handleConnectionCompleted_appendsFollowUpTurn() {
        let vm = makeVM()
        vm.handleConnectionCompleted(agentId: "google", displayName: "Google")
        let last = vm.messages.last(where: { $0.role == .user })?.text
        XCTAssertEqual(
            last,
            "I've connected Google. Please continue with my previous request."
        )
    }

    func test_handleConnectionCompleted_dedupesPerAgentId() {
        let vm = makeVM()
        vm.handleConnectionCompleted(agentId: "google", displayName: "Google")
        let firstCount = vm.messages.filter { $0.role == .user }.count
        vm.handleConnectionCompleted(agentId: "google", displayName: "Google")
        let secondCount = vm.messages.filter { $0.role == .user }.count
        XCTAssertEqual(
            firstCount, secondCount,
            "second tap for the SAME agent must NOT dispatch a duplicate follow-up"
        )
    }

    func test_handleConnectionCompleted_differentAgentIdsBothFire() {
        let vm = makeVM()
        vm.handleConnectionCompleted(agentId: "google", displayName: "Google")
        vm.handleConnectionCompleted(agentId: "lumo_rentals", displayName: "Lumo Rentals")
        XCTAssertGreaterThanOrEqual(
            vm.messages.filter { $0.role == .user }.count, 2,
            "connecting two distinct providers must both fire follow-up turns"
        )
    }
}
