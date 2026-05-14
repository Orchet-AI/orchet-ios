import Foundation

/// `composed_ui` SSE frame value — multi-section generative UI
/// envelope. Canonical contract:
/// orchet-backend/packages/domain-orchestrator/src/ui-catalog/index.ts
///
/// Layout values come from the backend; the dispatcher in
/// `ComposedUIView` picks a SwiftUI layout per case.
enum ComposedUILayout: String, Codable, Equatable {
    case stack
    case row
    case tabs
}

/// One section in a composed-UI frame. `props` is JSON the
/// dispatcher decodes per-component into the payload struct.
struct ComposedUISection: Codable, Equatable, Identifiable {
    /// Stable across decode of the same wire payload. The wire
    /// envelope doesn't carry an id; SwiftUI needs one for
    /// `ForEach` so we generate it on init and keep it on round-trip
    /// via a custom Codable conformance.
    let id: UUID
    let component: String
    let props: AnyCodable

    init(id: UUID = UUID(), component: String, props: AnyCodable) {
        self.id = id
        self.component = component
        self.props = props
    }

    enum CodingKeys: String, CodingKey {
        case component, props
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.component = try c.decode(String.self, forKey: .component)
        self.props = try c.decode(AnyCodable.self, forKey: .props)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(component, forKey: .component)
        try c.encode(props, forKey: .props)
    }
}

struct ComposedUIFrameValue: Codable, Equatable {
    let layout: ComposedUILayout
    let sections: [ComposedUISection]
}

/// Thin Codable wrapper around an arbitrary JSON value. The
/// dispatcher passes `props` back through JSONEncoder → typed
/// payload decoder, so we only need to round-trip without losing
/// fidelity (no need to expose a typed accessor).
struct AnyCodable: Codable, Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let v = try? container.decode(Bool.self) {
            self.value = v
        } else if let v = try? container.decode(Int.self) {
            self.value = v
        } else if let v = try? container.decode(Double.self) {
            self.value = v
        } else if let v = try? container.decode(String.self) {
            self.value = v
        } else if let v = try? container.decode([AnyCodable].self) {
            self.value = v.map { $0.value }
        } else if let v = try? container.decode([String: AnyCodable].self) {
            self.value = v.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map(AnyCodable.init))
        case let v as [String: Any]:
            try container.encode(v.mapValues(AnyCodable.init))
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Round-trip equality via JSON serialization. Good enough for
        // tests (the property under test is the decoder, not the
        // ad-hoc structural eq); avoids reflective Any comparison.
        let lhsData = (try? JSONEncoder().encode(lhs)) ?? Data()
        let rhsData = (try? JSONEncoder().encode(rhs)) ?? Data()
        return lhsData == rhsData
    }

    /// Re-decode the wrapped value as a concrete `Decodable` type.
    /// Returns nil on shape mismatch — the dispatcher silently drops
    /// sections whose props don't validate against the expected
    /// payload schema.
    func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// User gesture on a composed-UI card. The chat surface translates
/// each case into a natural-language follow-up turn via
/// `ChatViewModel.handleComposedAction`. Match the web translation
/// table verbatim — backend symmetry depends on it.
enum ComposedAction: Equatable {
    case cabBook(provider: String, tier: String)
    case restaurantConfirm(name: String, specialRequest: String?)
    case groceryPlaceOrder(provider: String, items: [GroceryOrderItem])
}

struct GroceryOrderItem: Equatable {
    let id: String
    let quantity: Double
}
