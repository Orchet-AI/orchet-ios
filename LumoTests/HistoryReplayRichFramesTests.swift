import XCTest
@testable import Lumo

/// Validates that a session reload restores search-cards / composed-ui /
/// connection-required cards under the assistant prose. Without this
/// reattach, switching back to an old chat thread silently drops every
/// rich card the user saw on the live turn.
///
/// Closes the gap web fixed in PR #17 (fix/reader-cap-and-search-cards-replay):
/// backend `/history/sessions/:id/messages` already returns these
/// frames embedded in each assistant message; iOS just wasn't decoding
/// them.
@MainActor
final class HistoryReplayRichFramesTests: XCTestCase {

    // MARK: - ReplayedMessageDTO Codable round-trip

    func test_replayedMessageDTO_decodesAllRichFrames() throws {
        let raw = #"""
        {
          "id": "h-001-assistant",
          "role": "assistant",
          "content": "Here are some results.",
          "created_at": "2026-05-16T10:00:00Z",
          "searchCards": {
            "lead_story_index": null,
            "cards": []
          },
          "composedUI": {
            "layout": "stack",
            "sections": [
              {"component": "CabOfferCard", "props": {"provider": "uber", "region": "US", "options": []}}
            ]
          },
          "connectionRequired": {
            "agent_id": "google",
            "display_name": "Google",
            "authorize_url": "https://api.orchet.ai/connections/google/authorize?state=abc",
            "blocked_tool": "gmail_search"
          }
        }
        """#
        let dto = try JSONDecoder().decode(ReplayedMessageDTO.self, from: Data(raw.utf8))
        XCTAssertEqual(dto.id, "h-001-assistant")
        XCTAssertNotNil(dto.searchCards)
        XCTAssertNotNil(dto.composedUI)
        XCTAssertEqual(dto.composedUI?.layout, .stack)
        XCTAssertNotNil(dto.connectionRequired)
        XCTAssertEqual(dto.connectionRequired?.agent_id, "google")
        XCTAssertTrue(dto.connectionRequired?.isRenderable ?? false)
    }

    func test_replayedMessageDTO_decodesWithNullOrMissingFrames() throws {
        // Server omits frames on plain-text assistant messages.
        let raw = #"""
        {"id":"h-002","role":"assistant","content":"Hi there.","created_at":"2026-05-16T10:00:01Z"}
        """#
        let dto = try JSONDecoder().decode(ReplayedMessageDTO.self, from: Data(raw.utf8))
        XCTAssertNil(dto.searchCards)
        XCTAssertNil(dto.composedUI)
        XCTAssertNil(dto.connectionRequired)
    }

    func test_replayedMessageDTO_explicitNullFramesAreNil() throws {
        let raw = #"""
        {"id":"h-003","role":"assistant","content":"Hi.","created_at":"2026-05-16T10:00:02Z","searchCards":null,"composedUI":null,"connectionRequired":null}
        """#
        let dto = try JSONDecoder().decode(ReplayedMessageDTO.self, from: Data(raw.utf8))
        XCTAssertNil(dto.searchCards)
        XCTAssertNil(dto.composedUI)
        XCTAssertNil(dto.connectionRequired)
    }

    // MARK: - ChatViewModel.loadSession reattach

    /// Stub fetcher that returns a deterministic replay payload —
    /// every method other than fetchSessionMessages traps because
    /// the loadSession path should never invoke them.
    final class FakeReplayFetcher: DrawerScreensFetching {
        let payload: SessionMessagesResponseDTO
        init(payload: SessionMessagesResponseDTO) { self.payload = payload }

        func fetchSessionMessages(sessionID: String) async throws -> SessionMessagesResponseDTO {
            payload
        }

        func fetchMemory() async throws -> MemoryResponseDTO { fatalError() }
        func fetchMarketplace() async throws -> MarketplaceResponseDTO { fatalError() }
        func fetchHistory(limitSessions: Int) async throws -> HistoryResponseDTO { fatalError() }
        func updateMemoryProfile(_ patch: MemoryProfilePatchDTO) async throws -> MemoryProfileDTO { fatalError() }
        func forgetMemoryFact(id: String) async throws { fatalError() }
        func installAgent(id: String) async throws -> String { fatalError() }
        func cancelTrip(id: String, reason: String?) async throws -> CancelTripResultDTO { fatalError() }
        func fetchConnections() async throws -> ConnectionsResponseDTO { fatalError() }
        func disconnectConnection(id: String) async throws { fatalError() }
        func markUserOnboarded(via: String) async throws { fatalError() }
        func connectMcpServer(serverID: String, accessToken: String) async throws { fatalError() }
    }

    private func makeSearchCards() -> SearchCardsFrameValue {
        SearchCardsFrameValue(leadStoryIndex: nil, cards: [])
    }

    private func makeComposedUI() -> ComposedUIFrameValue {
        ComposedUIFrameValue(layout: .stack, sections: [])
    }

    private func makeConnectionRequired() -> ConnectionRequiredFrameValue {
        ConnectionRequiredFrameValue(
            agent_id: "google",
            display_name: "Google",
            authorize_url: "https://api.orchet.ai/connections/google/authorize?state=abc",
            blocked_tool: "gmail_search"
        )
    }

    func test_loadSession_rehydratesAllRichFramesPerAssistantMessage() async {
        let messageDTO = ReplayedMessageDTO(
            id: "h-001-assistant",
            role: "assistant",
            content: "Here are results.",
            created_at: "2026-05-16T10:00:00Z",
            searchCards: makeSearchCards(),
            composedUI: makeComposedUI(),
            connectionRequired: makeConnectionRequired()
        )
        let payload = SessionMessagesResponseDTO(
            session_id: "session-abc",
            messages: [messageDTO]
        )
        let fetcher = FakeReplayFetcher(payload: payload)
        let svc = ChatService(baseURL: URL(string: "http://localhost:0")!)
        let vm = ChatViewModel(service: svc, historyFetcher: fetcher)

        await vm.loadSession(id: "session-abc")

        XCTAssertEqual(vm.messages.count, 1)
        let assistantMessageID = vm.messages[0].id
        XCTAssertNotNil(vm.searchCardsByMessage[assistantMessageID])
        XCTAssertNotNil(vm.composedUIByMessage[assistantMessageID])
        XCTAssertNotNil(vm.connectionRequiredByMessage[assistantMessageID])
        XCTAssertEqual(
            vm.connectionRequiredByMessage[assistantMessageID]?.agent_id,
            "google"
        )
    }

    func test_loadSession_skipsConnectionRequiredOnNonRenderableFrame() async {
        // Non-https authorize_url → isRenderable returns false → the
        // card should be DROPPED, not rehydrated. Privacy guard
        // protects against schema drift / replay rows with bad URLs.
        let bad = ConnectionRequiredFrameValue(
            agent_id: "x",
            display_name: "X",
            authorize_url: "javascript:alert(1)",
            blocked_tool: "foo"
        )
        let messageDTO = ReplayedMessageDTO(
            id: "h-bad",
            role: "assistant",
            content: "",
            created_at: "2026-05-16T10:00:00Z",
            searchCards: nil,
            composedUI: nil,
            connectionRequired: bad
        )
        let payload = SessionMessagesResponseDTO(session_id: "s", messages: [messageDTO])
        let fetcher = FakeReplayFetcher(payload: payload)
        let svc = ChatService(baseURL: URL(string: "http://localhost:0")!)
        let vm = ChatViewModel(service: svc, historyFetcher: fetcher)

        await vm.loadSession(id: "s")
        let id = vm.messages[0].id
        XCTAssertNil(
            vm.connectionRequiredByMessage[id],
            "non-https authorize_url must NOT rehydrate on replay"
        )
    }

    func test_loadSession_resetsAttachMapsBeforeRefilling() async {
        let payload1 = SessionMessagesResponseDTO(
            session_id: "session-1",
            messages: [
                ReplayedMessageDTO(
                    id: "a", role: "assistant", content: "A",
                    created_at: "2026-05-16T10:00:00Z",
                    searchCards: makeSearchCards(),
                    composedUI: nil, connectionRequired: nil
                ),
            ]
        )
        let payload2 = SessionMessagesResponseDTO(
            session_id: "session-2",
            messages: [
                ReplayedMessageDTO(
                    id: "b", role: "assistant", content: "B",
                    created_at: "2026-05-16T10:01:00Z",
                    searchCards: nil,
                    composedUI: makeComposedUI(),
                    connectionRequired: nil
                ),
            ]
        )
        let fetcher1 = FakeReplayFetcher(payload: payload1)
        let svc = ChatService(baseURL: URL(string: "http://localhost:0")!)
        let vm = ChatViewModel(service: svc, historyFetcher: fetcher1)

        await vm.loadSession(id: "session-1")
        XCTAssertEqual(vm.searchCardsByMessage.count, 1)

        // Swap to second session — old attach map must be cleared
        // before the new one repopulates, or the user sees orphan
        // cards from the prior thread.
        let vm2 = ChatViewModel(
            service: svc,
            historyFetcher: FakeReplayFetcher(payload: payload2)
        )
        await vm2.loadSession(id: "session-2")
        XCTAssertEqual(vm2.searchCardsByMessage.count, 0)
        XCTAssertEqual(vm2.composedUIByMessage.count, 1)
    }
}
