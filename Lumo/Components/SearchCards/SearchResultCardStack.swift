import SwiftUI

/// Top-level dispatcher for the `search_cards` SSE frame value.
/// Picks between two layouts and mounts the right card views.
///
///   leadStoryIndex == nil
///       Equal-weight grid: cards render as `CompactSearchCard
///       .gridCell` in an adaptive 2-up grid (iPhone) / 3-up grid
///       (iPad). No card is promoted.
///
///   leadStoryIndex == N
///       Featured layout: card at position N renders as
///       `FeaturedSearchCard` (large hero), the rest stack
///       underneath as `CompactSearchCard.featuredSecondary`
///       (horizontal mini-rows with 84pt thumbnails). Always
///       single-column on iPhone — at 380pt wide, a side-by-side
///       grid of horizontal cards would crush each title.
///
/// Mounted by `ChatView` directly under the assistant prose bubble
/// when `viewModel.searchCardsByMessage[message.id]` is non-nil.
/// The footer reuses the same source set as pill chips so users can
/// scan citations without re-reading the cards.
struct SearchResultCardStack: View {
    let value: SearchCardsFrameValue
    /// ORCHET-IOS-PARITY-1B — when supplied, card taps and source-
    /// chip taps fire this callback (the chat surface opens the
    /// reader sheet). Without it, cards fall back to the legacy
    /// `Link` behavior that jumps the user to Safari.
    var onCardTap: ((SearchCard) -> Void)? = nil

    var body: some View {
        if value.cards.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let leadIndex = value.leadStoryIndex,
                   leadIndex >= 0,
                   leadIndex < value.cards.count {
                    featuredLayout(leadIndex: leadIndex)
                } else {
                    equalWeightLayout
                }
                SearchCardsSourcesFooter(cards: value.cards, onTap: onCardTap)
            }
        }
    }

    @ViewBuilder
    private func featuredLayout(leadIndex: Int) -> some View {
        let lead = value.cards[leadIndex]
        let secondaries = value.cards
            .enumerated()
            .filter { $0.offset != leadIndex }
            .map { $0.element }
        VStack(alignment: .leading, spacing: 8) {
            FeaturedSearchCard(card: lead, onTap: onCardTap)
            ForEach(secondaries) { card in
                CompactSearchCard(card: card, style: .featuredSecondary, onTap: onCardTap)
            }
        }
    }

    private var equalWeightLayout: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8, alignment: .top),
                GridItem(.flexible(), spacing: 8, alignment: .top),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(value.cards) { card in
                CompactSearchCard(card: card, style: .gridCell, onTap: onCardTap)
            }
        }
    }
}
