import XCTest
@testable import Lumo

/// Verify the Swift port of orchet-web's marketplace filter pipeline
/// — same segment semantics, same query haystack, same sort order.
/// Web parity matters: a user switching from web to iOS should see
/// the same list under the same filters.
final class MarketplaceFiltersTests: XCTestCase {

    private func make(
        id: String,
        name: String = "Agent",
        oneLiner: String = "",
        domain: String = "",
        intents: [String] = [],
        source: String? = "lumo",
        installed: Bool = false,
        category: String? = nil
    ) -> MarketplaceAgentDTO {
        MarketplaceAgentDTO(
            agent_id: id,
            display_name: name,
            one_liner: oneLiner,
            domain: domain,
            intents: intents,
            install: installed ? MarketplaceInstallStateDTO(status: "installed", installed_at: nil) : nil,
            listing: category.map { MarketplaceListingDTO(category: $0, pricing_note: nil) },
            connect_model: nil,
            source: source
        )
    }

    func test_segment_all_matchesEverything() {
        let a = make(id: "a", installed: true)
        let b = make(id: "b", source: "coming_soon")
        XCTAssertTrue(MarketplaceFilters.matches(segment: .all, agent: a))
        XCTAssertTrue(MarketplaceFilters.matches(segment: .all, agent: b))
    }

    func test_segment_connected_onlyInstalled() {
        let installed = make(id: "a", installed: true)
        let available = make(id: "b", installed: false)
        XCTAssertTrue(MarketplaceFilters.matches(segment: .connected, agent: installed))
        XCTAssertFalse(MarketplaceFilters.matches(segment: .connected, agent: available))
    }

    func test_segment_available_excludesComingSoonAndConnected() {
        let comingSoon = make(id: "a", source: "coming_soon")
        let installed = make(id: "b", installed: true)
        let available = make(id: "c", source: "lumo", installed: false)
        XCTAssertFalse(MarketplaceFilters.matches(segment: .available, agent: comingSoon))
        XCTAssertFalse(MarketplaceFilters.matches(segment: .available, agent: installed))
        XCTAssertTrue(MarketplaceFilters.matches(segment: .available, agent: available))
    }

    func test_segment_review_onlyComingSoon() {
        let comingSoon = make(id: "a", source: "coming_soon")
        let lumo = make(id: "b", source: "lumo")
        XCTAssertTrue(MarketplaceFilters.matches(segment: .review, agent: comingSoon))
        XCTAssertFalse(MarketplaceFilters.matches(segment: .review, agent: lumo))
    }

    func test_segment_mcp_onlyMcp() {
        let mcp = make(id: "a", source: "mcp")
        let lumo = make(id: "b", source: "lumo")
        XCTAssertTrue(MarketplaceFilters.matches(segment: .mcp, agent: mcp))
        XCTAssertFalse(MarketplaceFilters.matches(segment: .mcp, agent: lumo))
    }

    func test_query_searchesDisplayNameOneLinerDomainCategoryIntents() {
        let agent = make(
            id: "a",
            name: "Duffel Flights",
            oneLiner: "Search and book flights worldwide",
            domain: "flights",
            intents: ["plan_trip", "book_flight"],
            category: "Travel"
        )
        XCTAssertTrue(MarketplaceFilters.matches(query: "duffel", agent: agent))
        XCTAssertTrue(MarketplaceFilters.matches(query: "FLIGHTS", agent: agent))
        XCTAssertTrue(MarketplaceFilters.matches(query: "travel", agent: agent))
        XCTAssertTrue(MarketplaceFilters.matches(query: "plan_trip", agent: agent))
        XCTAssertFalse(MarketplaceFilters.matches(query: "rocket", agent: agent))
    }

    func test_query_empty_matchesAll() {
        let agent = make(id: "a", name: "Anything")
        XCTAssertTrue(MarketplaceFilters.matches(query: "", agent: agent))
        XCTAssertTrue(MarketplaceFilters.matches(query: "   ", agent: agent))
    }

    func test_sort_connectedFirst_thenAvailable_thenComingSoon() {
        let connected = make(id: "a", name: "Banana", installed: true)
        let available = make(id: "b", name: "Apple", source: "lumo")
        let comingSoon = make(id: "c", name: "Aardvark", source: "coming_soon")
        let sorted = MarketplaceFilters.sorted([comingSoon, available, connected])
        XCTAssertEqual(sorted.map(\.agent_id), ["a", "b", "c"])
    }

    func test_sort_tiebreaksByDisplayName() {
        let a = make(id: "1", name: "Charlie", source: "lumo")
        let b = make(id: "2", name: "Alpha", source: "lumo")
        let c = make(id: "3", name: "Bravo", source: "lumo")
        let sorted = MarketplaceFilters.sorted([a, b, c])
        XCTAssertEqual(sorted.map(\.display_name), ["Alpha", "Bravo", "Charlie"])
    }

    func test_filterAndSort_pipelinesQueryAndSegmentAndCategory() {
        let agents = [
            make(id: "a", name: "Flight Connect", domain: "flights", source: "lumo", category: "Travel"),
            make(id: "b", name: "Hotel Connect", domain: "hotels", source: "lumo", category: "Travel"),
            make(id: "c", name: "Spotify", domain: "music", source: "lumo", category: "Entertainment"),
            make(id: "d", name: "Future Thing", source: "coming_soon"),
        ]
        let result = MarketplaceFilters.filterAndSort(
            agents: agents,
            segment: .available,
            query: "connect",
            category: "Travel"
        )
        XCTAssertEqual(result.map(\.agent_id).sorted(), ["a", "b"])
    }

    func test_categories_listsUniqueSortedWithAllSentinel() {
        let agents = [
            make(id: "a", category: "Travel"),
            make(id: "b", category: "Travel"),
            make(id: "c", category: "Food & Drink"),
            make(id: "d", category: nil),
        ]
        XCTAssertEqual(
            MarketplaceFilters.categories(for: agents),
            ["all", "Food & Drink", "Travel"]
        )
    }

    func test_counts_breakdown() {
        let agents = [
            make(id: "a", installed: true),
            make(id: "b", source: "lumo"),
            make(id: "c", source: "coming_soon"),
            make(id: "d", source: "mcp"),
        ]
        let counts = MarketplaceFilters.counts(for: agents)
        XCTAssertEqual(counts.total, 4)
        XCTAssertEqual(counts.connected, 1)
        XCTAssertEqual(counts.review, 1)
        XCTAssertEqual(counts.mcp, 1)
        XCTAssertEqual(counts.available, 3) // everything except coming_soon
    }
}
