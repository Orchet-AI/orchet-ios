import SwiftUI

/// Trailing sources strip below a `SearchResultCardStack`. Renders
/// one pill chip per card linking to its `sourceURL`. Matches the
/// web side's "Sources · N" footer (`orchet-web/components/
/// SearchResultCards.tsx`) — same visual weight, same single-row
/// wrap, same total-count badge.
///
/// Wraps to multiple lines when the host count or label length
/// exceeds the row — SwiftUI's `LazyVGrid` with adaptive columns
/// handles the wrap without forcing a horizontal scroll.
struct SearchCardsSourcesFooter: View {
    let cards: [SearchCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chipsFlow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("SOURCES · \(cards.count)")
                .font(.system(size: 10.5, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
        }
    }

    private var chipsFlow: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 90, maximum: 200), spacing: 5, alignment: .leading),
            ],
            alignment: .leading,
            spacing: 5
        ) {
            ForEach(cards) { card in
                sourceChip(card)
            }
        }
    }

    @ViewBuilder
    private func sourceChip(_ card: SearchCard) -> some View {
        if let url = URL(string: card.sourceURL) {
            Link(destination: url) {
                chipLabel(for: card)
            }
            .buttonStyle(.plain)
        } else {
            chipLabel(for: card)
        }
    }

    private func chipLabel(for card: SearchCard) -> some View {
        Text(shortLabel(host: card.sourceHost, title: card.title))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color(.secondarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
            )
    }

    private func shortLabel(host: String, title: String) -> String {
        if host.count <= 24 { return host }
        let prefix = host.split(separator: ".").first.map(String.init) ?? host
        let firstWord = title.split(separator: " ").first.map(String.init) ?? ""
        return firstWord.isEmpty ? prefix : "\(prefix) · \(firstWord)"
    }
}
