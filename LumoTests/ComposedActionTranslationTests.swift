import XCTest
@testable import Lumo

/// ORCHET-IOS-PARITY-1C — verify the natural-language translation
/// table that ChatViewModel.handleComposedAction uses to turn a
/// card gesture into a follow-up text turn. Matches web's
/// `handleComposedAction` translation verbatim — backend symmetry
/// depends on it.
///
/// We assert against the appended user-bubble text instead of
/// intercepting the network call: ChatService is final and has no
/// protocol, but `startStream` appends the prompt to `messages`
/// synchronously before the stream task starts.
@MainActor
final class ComposedActionTranslationTests: XCTestCase {

    private func makeVM() -> ChatViewModel {
        let service = ChatService(baseURL: URL(string: "http://localhost:0")!)
        return ChatViewModel(service: service)
    }

    private func appendedPrompt(_ vm: ChatViewModel) -> String? {
        vm.messages.last(where: { $0.role == .user })?.text
    }

    func test_cabBook_promptsBookTierOnProvider() async {
        let vm = makeVM()
        vm.handleComposedAction(.cabBook(provider: "uber", tier: "UberX"))
        XCTAssertEqual(appendedPrompt(vm), "Book the UberX on uber.")
    }

    func test_restaurantConfirm_withoutRequest_promptsConfirmAtName() async {
        let vm = makeVM()
        vm.handleComposedAction(.restaurantConfirm(name: "Nopa", specialRequest: nil))
        XCTAssertEqual(appendedPrompt(vm), "Confirm the reservation at Nopa.")
    }

    func test_restaurantConfirm_withRequest_appendsSpecialRequest() async {
        let vm = makeVM()
        vm.handleComposedAction(.restaurantConfirm(name: "Nopa", specialRequest: "window seat"))
        XCTAssertEqual(
            appendedPrompt(vm),
            "Confirm the reservation at Nopa. Special request: window seat."
        )
    }

    func test_groceryPlaceOrder_formatsQuantityAndItem() async {
        let vm = makeVM()
        vm.handleComposedAction(.groceryPlaceOrder(
            provider: "instacart",
            items: [
                GroceryOrderItem(id: "sku-1", quantity: 2),
                GroceryOrderItem(id: "sku-2", quantity: 1.5),
            ]
        ))
        XCTAssertEqual(appendedPrompt(vm), "Place the instacart order: 2× sku-1, 1.5× sku-2.")
    }

    func test_groceryPlaceOrder_skipsZeroQuantityItems() async {
        let vm = makeVM()
        vm.handleComposedAction(.groceryPlaceOrder(
            provider: "blinkit",
            items: [
                GroceryOrderItem(id: "sku-1", quantity: 0),
                GroceryOrderItem(id: "sku-2", quantity: 1),
            ]
        ))
        XCTAssertEqual(appendedPrompt(vm), "Place the blinkit order: 1× sku-2.")
    }
}
