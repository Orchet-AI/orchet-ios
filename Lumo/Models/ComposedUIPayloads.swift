import Foundation

// MARK: - Cab

struct CabAddress: Codable, Equatable {
    let address: String?
}

struct CabOption: Codable, Equatable, Identifiable {
    var id: String { tier_name ?? UUID().uuidString }
    let tier_name: String?
    let price: Double?
    let capacity: Int?
    /// `"now" | "scheduled"` — never enforced by the type; treat as
    /// presentational hint only.
    let hailing: String?
}

struct CabOfferPayload: Codable, Equatable {
    let provider: String
    let region: String
    let currency: String?
    let pickup: CabAddress?
    let dropoff: CabAddress?
    let eta_minutes: Double?
    let surge_multiplier: Double?
    let options: [CabOption]
}

// MARK: - Restaurant

struct RestaurantBookingPayload: Codable, Equatable {
    let restaurant_name: String
    let restaurant_id: String?
    let provider: String?
    let cuisine: String?
    let rating: Double?
    let slot_start: String
    let slot_end: String?
    let party_size: Int
    let address: String?
    let phone: String?
    let special_request_supported: Bool?
}

// MARK: - Grocery

struct GroceryItem: Codable, Equatable, Identifiable {
    var id: String { item_id ?? UUID().uuidString }
    let item_id: String?
    let name: String?
    let quantity: Double?
    let unit: String?
    let price: Double?
    let image_url: String?

    enum CodingKeys: String, CodingKey {
        case item_id = "id"
        case name, quantity, unit, price, image_url
    }
}

struct GroceryCartPayload: Codable, Equatable {
    let provider: String
    let region: String?
    let currency: String
    let items: [GroceryItem]
    let subtotal: Double?
    let taxes: Double?
    let delivery_fee: Double?
    let total: Double
    let delivery_window_start: String?
    let delivery_window_end: String?
}
