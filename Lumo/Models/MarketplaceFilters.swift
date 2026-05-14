import Foundation

/// Port of orchet-web `lib/presenters/marketplace/marketplace-ui.ts`.
/// Same segment names, same match semantics, same sort order so iOS
/// users see exactly what web users see.

enum MarketplaceSegment: String, CaseIterable, Identifiable {
    case all
    case connected
    case available
    case review
    case mcp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .connected: return "Connected"
        case .available: return "Available"
        case .review: return "Review only"
        case .mcp: return "MCP"
        }
    }
}

struct MarketplaceCounts: Equatable {
    let total: Int
    let connected: Int
    let available: Int
    let review: Int
    let mcp: Int
}

enum MarketplaceFilters {
    /// "connected" = isInstalled OR has an active OAuth connection.
    /// iOS DTO doesn't carry the OAuth `connection.status` today, so
    /// we proxy via `isInstalled` — same semantics for first-party
    /// agents. When the DTO gains a connection field we extend this
    /// helper without changing call sites.
    static func isConnected(_ agent: MarketplaceAgentDTO) -> Bool {
        agent.isInstalled
    }

    static func counts(for agents: [MarketplaceAgentDTO]) -> MarketplaceCounts {
        var connected = 0
        var available = 0
        var review = 0
        var mcp = 0
        for agent in agents {
            if isConnected(agent) { connected += 1 }
            if agent.source == "coming_soon" { review += 1 }
            else { available += 1 }
            if agent.source == "mcp" { mcp += 1 }
        }
        return MarketplaceCounts(
            total: agents.count,
            connected: connected,
            available: available,
            review: review,
            mcp: mcp
        )
    }

    static func matches(segment: MarketplaceSegment, agent: MarketplaceAgentDTO) -> Bool {
        switch segment {
        case .all:
            return true
        case .connected:
            return isConnected(agent)
        case .available:
            return agent.source != "coming_soon" && !isConnected(agent)
        case .review:
            return agent.source == "coming_soon"
        case .mcp:
            return agent.source == "mcp"
        }
    }

    static func matches(query: String, agent: MarketplaceAgentDTO) -> Bool {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.isEmpty { return true }
        let haystack = [
            agent.display_name,
            agent.one_liner,
            agent.domain,
            agent.listing?.category ?? "",
        ].joined(separator: " ").lowercased()
            + " "
            + agent.intents.joined(separator: " ").lowercased()
        return haystack.contains(normalized)
    }

    /// Mirrors web's sortMarketplaceAgents: connected first,
    /// available next, coming-soon last; tiebreak by display name.
    static func sorted(_ agents: [MarketplaceAgentDTO]) -> [MarketplaceAgentDTO] {
        agents.sorted { a, b in
            let ra = rank(a)
            let rb = rank(b)
            if ra != rb { return ra < rb }
            return a.display_name
                .localizedCaseInsensitiveCompare(b.display_name) == .orderedAscending
        }
    }

    private static func rank(_ agent: MarketplaceAgentDTO) -> Int {
        if isConnected(agent) { return 0 }
        if agent.source != "coming_soon" { return 1 }
        return 2
    }

    /// Category keys (web stores them on `listing.category`). Returns
    /// a stable sorted list with "all" sentinel first.
    static func categories(for agents: [MarketplaceAgentDTO]) -> [String] {
        var set = Set<String>()
        for agent in agents {
            if let cat = agent.listing?.category, !cat.isEmpty {
                set.insert(cat)
            }
        }
        return ["all"] + set.sorted()
    }

    /// Returns the filtered + sorted list for the given (segment,
    /// query, category) tuple. Matches web's combined filter pipeline
    /// exactly.
    static func filterAndSort(
        agents: [MarketplaceAgentDTO],
        segment: MarketplaceSegment,
        query: String,
        category: String
    ) -> [MarketplaceAgentDTO] {
        let sorted = self.sorted(agents)
        return sorted.filter { agent in
            let categoryOK = category == "all" || agent.listing?.category == category
            return categoryOK
                && matches(segment: segment, agent: agent)
                && matches(query: query, agent: agent)
        }
    }
}
