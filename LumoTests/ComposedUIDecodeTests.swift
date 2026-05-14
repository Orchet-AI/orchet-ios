import XCTest
@testable import Lumo

/// ORCHET-IOS-PARITY-1C — frame-decode + drop-on-invalid behavior
/// for the composed_ui dispatcher. Fixture JSON mirrors the wire
/// shape the orchestrator emits.
final class ComposedUIDecodeTests: XCTestCase {

    private func decode(_ json: String) -> ComposedUIFrameValue? {
        try? JSONDecoder().decode(ComposedUIFrameValue.self, from: Data(json.utf8))
    }

    func test_cabPlusRestaurantStack_decodesBothSections() throws {
        let raw = """
        {
          "layout": "stack",
          "sections": [
            {
              "component": "CabOfferCard",
              "props": {
                "provider": "uber",
                "region": "US",
                "currency": "USD",
                "options": [{"tier_name":"UberX","price":18,"capacity":4,"hailing":"now"}]
              }
            },
            {
              "component": "RestaurantBookingCard",
              "props": {
                "restaurant_name": "Nopa",
                "slot_start": "2026-05-14T19:00:00Z",
                "party_size": 2
              }
            }
          ]
        }
        """
        let frame = try XCTUnwrap(decode(raw))
        XCTAssertEqual(frame.layout, .stack)
        XCTAssertEqual(frame.sections.count, 2)
        XCTAssertEqual(frame.sections[0].component, "CabOfferCard")
        XCTAssertEqual(frame.sections[1].component, "RestaurantBookingCard")

        // Round-trip through the typed payload decoder.
        let cab = frame.sections[0].props.decoded(as: CabOfferPayload.self)
        XCTAssertNotNil(cab)
        XCTAssertEqual(cab?.provider, "uber")
        XCTAssertEqual(cab?.options.first?.tier_name, "UberX")

        let restaurant = frame.sections[1].props.decoded(as: RestaurantBookingPayload.self)
        XCTAssertNotNil(restaurant)
        XCTAssertEqual(restaurant?.party_size, 2)
    }

    func test_unknownComponent_decodesButDropsInDispatcher() throws {
        let raw = """
        {
          "layout": "stack",
          "sections": [
            {"component":"FooCard","props":{"hello":"world"}},
            {"component":"CabOfferCard","props":{"provider":"lyft","region":"US","options":[]}}
          ]
        }
        """
        let frame = try XCTUnwrap(decode(raw))
        XCTAssertEqual(frame.sections.count, 2)
        // The dispatcher's renderableSections is private, but its
        // contract is: unknown components produce 0 rendered cards
        // while valid siblings still render. We can't directly probe
        // it from here — verify the underlying decode succeeds and
        // siblings still typed-decode.
        XCTAssertNil(frame.sections[0].props.decoded(as: CabOfferPayload.self))
        XCTAssertNotNil(frame.sections[1].props.decoded(as: CabOfferPayload.self))
    }

    func test_cabMissingProvider_typedDecodeFails_dispatcherDropsSection() throws {
        // Backend always emits `provider`; if a future build sends a
        // missing-field payload the typed decoder must drop it so
        // the dispatcher renders nothing for that slot.
        let raw = """
        {
          "layout": "row",
          "sections": [
            {"component":"CabOfferCard","props":{"region":"US","options":[]}}
          ]
        }
        """
        let frame = try XCTUnwrap(decode(raw))
        let cab = frame.sections[0].props.decoded(as: CabOfferPayload.self)
        XCTAssertNil(cab, "provider is required; decode must fail")
    }

    func test_groceryCart_typedDecode_preservesItemList() throws {
        let raw = """
        {
          "layout": "stack",
          "sections": [
            {
              "component": "GroceryCartCard",
              "props": {
                "provider": "instacart",
                "currency": "USD",
                "items": [
                  {"id":"sku-1","name":"Bananas","quantity":3,"unit":"pcs","price":1.5},
                  {"id":"sku-2","name":"Milk","quantity":1,"unit":"gal","price":4}
                ],
                "subtotal": 8.5,
                "taxes": 0.5,
                "delivery_fee": 3.0,
                "total": 12.0,
                "delivery_window_start": "2026-05-14T18:00:00Z",
                "delivery_window_end": "2026-05-14T19:00:00Z"
              }
            }
          ]
        }
        """
        let frame = try XCTUnwrap(decode(raw))
        let grocery = try XCTUnwrap(frame.sections[0].props.decoded(as: GroceryCartPayload.self))
        XCTAssertEqual(grocery.items.count, 2)
        XCTAssertEqual(grocery.items.first?.name, "Bananas")
        XCTAssertEqual(grocery.total, 12.0)
    }

    func test_emptySections_decodes() throws {
        let raw = #"{"layout":"stack","sections":[]}"#
        let frame = try XCTUnwrap(decode(raw))
        XCTAssertEqual(frame.sections.count, 0)
    }

    func test_unknownLayout_failsDecode() {
        let raw = #"{"layout":"carousel","sections":[]}"#
        XCTAssertNil(decode(raw))
    }
}
