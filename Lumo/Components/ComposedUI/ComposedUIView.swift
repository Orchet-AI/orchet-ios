import SwiftUI

/// Multi-section dispatcher for the `composed_ui` SSE frame. Iterates
/// the sections, decodes each one's props into the matching payload
/// struct, and renders the right card view. Unknown components and
/// decode failures are silently dropped — parity with the web
/// dispatcher's `validateAgainstSchema` drop semantic.
struct ComposedUIView: View {
    let frame: ComposedUIFrameValue
    let onAction: (ComposedAction) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        let rendered = renderableSections
        if rendered.isEmpty {
            EmptyView()
        } else {
            container(for: rendered)
        }
    }

    @ViewBuilder
    private func container(for sections: [RenderedSection]) -> some View {
        switch frame.layout {
        case .stack:
            VStack(spacing: LumoSpacing.md) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        case .row:
            if horizontalSizeClass == .regular || sections.count <= 1 {
                HStack(alignment: .top, spacing: LumoSpacing.md) {
                    ForEach(sections) { section in
                        sectionView(section)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                VStack(spacing: LumoSpacing.md) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
            }
        case .tabs:
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: LumoSpacing.md, alignment: .top),
                    GridItem(.flexible(), spacing: LumoSpacing.md, alignment: .top),
                ],
                spacing: LumoSpacing.md
            ) {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: RenderedSection) -> some View {
        switch section.kind {
        case .cab(let payload):
            CabOfferCardView(payload: payload) { tier in
                onAction(.cabBook(provider: payload.provider, tier: tier))
            }
        case .restaurant(let payload):
            RestaurantBookingCardView(payload: payload) { request in
                onAction(.restaurantConfirm(name: payload.restaurant_name, specialRequest: request))
            }
        case .grocery(let payload):
            GroceryCartCardView(payload: payload) { items in
                onAction(.groceryPlaceOrder(provider: payload.provider, items: items))
            }
        }
    }

    private var renderableSections: [RenderedSection] {
        var out: [RenderedSection] = []
        for section in frame.sections {
            switch section.component {
            case "CabOfferCard":
                if let p = section.props.decoded(as: CabOfferPayload.self) {
                    out.append(RenderedSection(id: section.id, kind: .cab(p)))
                }
            case "RestaurantBookingCard":
                if let p = section.props.decoded(as: RestaurantBookingPayload.self) {
                    out.append(RenderedSection(id: section.id, kind: .restaurant(p)))
                }
            case "GroceryCartCard":
                if let p = section.props.decoded(as: GroceryCartPayload.self) {
                    out.append(RenderedSection(id: section.id, kind: .grocery(p)))
                }
            default:
                continue
            }
        }
        return out
    }

    private struct RenderedSection: Identifiable {
        let id: UUID
        let kind: Kind

        enum Kind {
            case cab(CabOfferPayload)
            case restaurant(RestaurantBookingPayload)
            case grocery(GroceryCartPayload)
        }
    }
}
