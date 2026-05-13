import XCTest
@testable import Lumo

/// Tests for the `search_cards` SSE frame parser case in
/// `ChatService.parseFrame`. Pairs with the backend envelope shape
/// in `orchet-backend/packages/domain-orchestrator/src/executor/
/// search-cards.ts` — these fixtures are deliberately structured to
/// match what that file emits.
final class SearchCardsParseTests: XCTestCase {

    // MARK: - Happy path

    func test_parseFrame_searchCards_decodesAllFields() throws {
        let line = #"data:{"type":"search_cards","value":{"lead_story_index":0,"cards":[{"id":"card_0","title":"Gemini intelligence","summary":"Proactive AI in Android.","source_url":"https://blog.google/products/gemini","source_host":"blog.google","image_url":"https://blog.google/img/g.jpg","category":"AI","category_icon":"sparkles","read_time_minutes":3},{"id":"card_1","title":"Googlebook laptops","summary":"New category, Gemini at the core.","source_url":"https://store.google.com/category/googlebook","source_host":"store.google.com","image_url":null,"category":"Hardware","category_icon":"device-laptop","read_time_minutes":null}]}}"#
        let event = try XCTUnwrap(ChatService.parseFrame(line: line))
        guard case .searchCards(let value) = event else {
            return XCTFail("Expected .searchCards, got \(event)")
        }
        XCTAssertEqual(value.leadStoryIndex, 0)
        XCTAssertEqual(value.cards.count, 2)
        let lead = value.cards[0]
        XCTAssertEqual(lead.id, "card_0")
        XCTAssertEqual(lead.title, "Gemini intelligence")
        XCTAssertEqual(lead.summary, "Proactive AI in Android.")
        XCTAssertEqual(lead.sourceURL, "https://blog.google/products/gemini")
        XCTAssertEqual(lead.sourceHost, "blog.google")
        XCTAssertEqual(lead.imageURL, "https://blog.google/img/g.jpg")
        XCTAssertEqual(lead.category, "AI")
        XCTAssertEqual(lead.categoryIcon, "sparkles")
        XCTAssertEqual(lead.readTimeMinutes, 3)
        let secondary = value.cards[1]
        XCTAssertNil(secondary.imageURL)
        XCTAssertNil(secondary.readTimeMinutes)
    }

    func test_parseFrame_searchCards_nullLeadStoryIndex_decodesAsNil() throws {
        let line = #"data:{"type":"search_cards","value":{"lead_story_index":null,"cards":[{"id":"a","title":"t","summary":"s","source_url":"https://x.test","source_host":"x.test","image_url":null,"category":"World","category_icon":"world","read_time_minutes":null}]}}"#
        let event = try XCTUnwrap(ChatService.parseFrame(line: line))
        guard case .searchCards(let value) = event else {
            return XCTFail("Expected .searchCards, got \(event)")
        }
        XCTAssertNil(value.leadStoryIndex)
        XCTAssertEqual(value.cards.count, 1)
    }

    // MARK: - Defensive paths

    func test_parseFrame_searchCards_emptyCards_fallsBackToOther() {
        let line = #"data:{"type":"search_cards","value":{"lead_story_index":null,"cards":[]}}"#
        let event = ChatService.parseFrame(line: line)
        XCTAssertEqual(event, .other(type: "search_cards"))
    }

    func test_parseFrame_searchCards_missingCardsField_fallsBackToOther() {
        let line = #"data:{"type":"search_cards","value":{"lead_story_index":0}}"#
        let event = ChatService.parseFrame(line: line)
        XCTAssertEqual(event, .other(type: "search_cards"))
    }

    func test_parseFrame_searchCards_cardMissingRequiredField_fallsBackToOther() {
        let line = #"data:{"type":"search_cards","value":{"lead_story_index":null,"cards":[{"id":"a","title":"t"}]}}"#
        let event = ChatService.parseFrame(line: line)
        XCTAssertEqual(event, .other(type: "search_cards"))
    }

    func test_parseFrame_searchCards_unknownCategoryIconRoundtripsRaw() throws {
        let line = #"data:{"type":"search_cards","value":{"lead_story_index":null,"cards":[{"id":"a","title":"t","summary":"s","source_url":"https://x.test","source_host":"x.test","image_url":null,"category":"Quantum","category_icon":"qubit","read_time_minutes":null}]}}"#
        let event = try XCTUnwrap(ChatService.parseFrame(line: line))
        guard case .searchCards(let value) = event else {
            return XCTFail("Expected .searchCards")
        }
        XCTAssertEqual(value.cards[0].category, "Quantum")
        XCTAssertEqual(value.cards[0].categoryIcon, "qubit")
        XCTAssertEqual(SearchCardSymbol.sfName(for: value.cards[0].categoryIcon), "globe")
        XCTAssertEqual(
            SearchCardCategoryTheme.theme(for: value.cards[0].category).background,
            SearchCardCategoryTheme.fallback.background
        )
    }
}
