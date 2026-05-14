import SwiftUI

/// Compact card variant. Renders in two layouts driven by `.style`:
///
///   .gridCell             vertical, hero on top (96pt), title +
///                          summary below. Used when the parent
///                          frame has no lead story and the cards
///                          render as an equal-weight 2-up grid
///                          (iPhone) / 3-up grid (iPad).
///
///   .featuredSecondary    horizontal, 84pt-wide colored thumbnail
///                          on the left, content on the right. Used
///                          when a `FeaturedSearchCard` is rendered
///                          and the rest are stacked secondaries
///                          under it. Single-column on iPhone.
///
/// One file for both layouts because the data + interaction model
/// is identical — only the frame geometry differs. Splitting into
/// two files would duplicate the AsyncImage fallback and the link
/// handling for no benefit.
struct CompactSearchCard: View {
    enum Style {
        case gridCell
        case featuredSecondary
    }

    let card: SearchCard
    let style: Style
    /// ORCHET-IOS-PARITY-1B — see `FeaturedSearchCard.onTap`.
    var onTap: ((SearchCard) -> Void)? = nil

    private var theme: SearchCardTheme {
        SearchCardCategoryTheme.theme(for: card.category)
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

    @ViewBuilder
    private var content: some View {
        switch style {
        case .gridCell:
            gridCellContent
        case .featuredSecondary:
            featuredSecondaryContent
        }
    }

    private var gridCellContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroBlock(height: 96, iconSize: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(card.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(card.sourceHost)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
    }

    private var featuredSecondaryContent: some View {
        HStack(alignment: .top, spacing: 0) {
            heroThumb
            VStack(alignment: .leading, spacing: 3) {
                CategoryChip(label: card.category, theme: theme)
                Text(card.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(card.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(card.sourceHost)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5)
        )
    }

    private func heroBlock(height: CGFloat, iconSize: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let urlString = card.imageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        iconFallback(iconSize: iconSize)
                    @unknown default:
                        iconFallback(iconSize: iconSize)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
            } else {
                iconFallback(iconSize: iconSize)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
            CategoryChip(label: card.category, theme: theme)
                .padding(.top, 10)
                .padding(.leading, 12)
        }
    }

    private var heroThumb: some View {
        ZStack {
            if let urlString = card.imageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        thumbFallback
                    @unknown default:
                        thumbFallback
                    }
                }
            } else {
                thumbFallback
            }
        }
        .frame(width: 84)
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private var thumbFallback: some View {
        ZStack {
            theme.background
            CategoryIconView(
                categoryIcon: card.categoryIcon,
                theme: theme,
                size: 30
            )
        }
    }

    private func iconFallback(iconSize: CGFloat) -> some View {
        ZStack {
            theme.background
            CategoryIconView(
                categoryIcon: card.categoryIcon,
                theme: theme,
                size: iconSize
            )
        }
    }
}
