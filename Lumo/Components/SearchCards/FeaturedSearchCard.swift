import SwiftUI

/// Lead-story card variant. Renders the editorial headliner of a
/// `search_cards` frame — large hero (180pt iPhone / 220pt iPad),
/// h2 title (17pt), 3-line body (13.5pt), and a meta row pairing the
/// source host with an optional read-time hint. The full card body
/// is one tap target so users don't have to aim for the title or
/// the source link separately.
///
/// Image strategy: SwiftUI's `AsyncImage` covers the hero block
/// when `imageURL` is non-nil and resolves cleanly. On nil URL or
/// load failure we fall back to a flat category-themed block with
/// a single large outline SF Symbol — no gradients, no decorative
/// shimmer, matches the design system's hero-block rules.
struct FeaturedSearchCard: View {
    let card: SearchCard
    /// ORCHET-IOS-PARITY-1B — tap-handler hooked up by
    /// `SearchResultCardStack`. When supplied, the card becomes a
    /// `Button` that fires `onTap(card)` (the chat surface opens
    /// the reader sheet). When nil, the card stays a `Link` for
    /// the legacy out-to-Safari behavior so older call sites still
    /// work without modification.
    var onTap: ((SearchCard) -> Void)? = nil

    private var theme: SearchCardTheme {
        SearchCardCategoryTheme.theme(for: card.category)
    }

    private var heroHeight: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 220 : 180
    }

    private var destinationURL: URL? {
        URL(string: card.sourceURL)
    }

    var body: some View {
        Group {
            if let onTap {
                Button { onTap(card) } label: { content }
                    .buttonStyle(.plain)
            } else if let url = destinationURL {
                Link(destination: url) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroBlock
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(card.summary)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                metaRow
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
    }

    private var heroBlock: some View {
        ZStack(alignment: .topLeading) {
            if let urlString = card.imageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        iconFallback
                    @unknown default:
                        iconFallback
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: heroHeight)
                .clipped()
            } else {
                iconFallback
                    .frame(maxWidth: .infinity)
                    .frame(height: heroHeight)
            }
            CategoryChip(
                label: "Lead story",
                theme: theme
            )
            .padding(.top, 12)
            .padding(.leading, 14)
        }
    }

    private var iconFallback: some View {
        ZStack {
            theme.background
            CategoryIconView(
                categoryIcon: card.categoryIcon,
                theme: theme,
                size: 76
            )
        }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .regular))
                Text(card.sourceHost)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)

            if let minutes = card.readTimeMinutes {
                Text("·").foregroundStyle(.tertiary)
                Text("\(minutes) min read")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Pill chip used in the hero block + the compact card. Background is
/// the 900 stop of the category ramp; text is the 50 stop. Same
/// contrast pairing the web side uses so chips read identical on
/// both surfaces.
struct CategoryChip: View {
    let label: String
    let theme: SearchCardTheme

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(theme.chipText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(theme.chipBackground)
            )
    }
}
