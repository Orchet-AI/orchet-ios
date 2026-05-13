import Foundation

/// Wire shape for one card in the `search_cards` SSE frame value.
///
/// Canonical contract — orchet-backend
/// `packages/domain-orchestrator/src/executor/search-cards.ts`.
/// Keep field names in lockstep with that file; the JSON arrives
/// snake_cased so we use a CodingKeys map to keep idiomatic Swift
/// property names on the read side.
///
/// Forward-compat: every field optional that the server might omit on
/// older builds (image_url, read_time_minutes). New fields added by
/// the server stay un-modelled until we use them — Swift's Decodable
/// drops unknown keys silently.
struct SearchCard: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let sourceURL: String
    let sourceHost: String
    let imageURL: String?
    let category: String
    let categoryIcon: String
    let readTimeMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case sourceURL = "source_url"
        case sourceHost = "source_host"
        case imageURL = "image_url"
        case category
        case categoryIcon = "category_icon"
        case readTimeMinutes = "read_time_minutes"
    }
}

/// Wire shape for the whole `search_cards` SSE frame value.
struct SearchCardsFrameValue: Codable, Hashable {
    /// Index into `cards` for the editorial lead. nil => render as an
    /// equal-weight 3-up grid. When set, the card at that position
    /// renders in the featured variant.
    let leadStoryIndex: Int?
    let cards: [SearchCard]

    enum CodingKeys: String, CodingKey {
        case leadStoryIndex = "lead_story_index"
        case cards
    }
}
