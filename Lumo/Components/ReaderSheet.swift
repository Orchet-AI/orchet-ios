import SwiftUI

/// SwiftUI sheet that renders a reader-mode article fetched by
/// `ReaderSheetController`. Mounts via
/// `.sheet(item: $controller.activeCard)` on the chat surface.
///
/// Mirrors the web `<ReaderDrawer>` layout 1:1:
///   • Header — source_host + Open-in-Safari + close.
///   • Hero  — async-loaded `lead_image_url`, fallback to category
///             tile when image is nil or load fails.
///   • Title + byline + publish date.
///   • Body — html→md→AttributedString via `ReaderArticleBody`.
struct ReaderSheet: View {
    @ObservedObject var controller: ReaderSheetController
    let card: SearchCard

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LumoSpacing.lg) {
                    heroImage
                        .padding(.bottom, LumoSpacing.xs)
                    titleBlock
                    bodyContent
                }
                .padding(LumoSpacing.lg)
            }
            .background(LumoColors.background.ignoresSafeArea())
            .navigationTitle(card.sourceHost)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityIdentifier("reader.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let url = URL(string: card.sourceURL) {
                            openURL(url)
                        }
                    } label: {
                        Image(systemName: "safari")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityIdentifier("reader.openInSafari")
                }
            }
        }
    }

    @ViewBuilder
    private var heroImage: some View {
        let urlString = readerStateArticle()?.leadImageURL ?? card.imageURL
        if let urlString, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholderHero
                case .empty:
                    LumoColors.surfaceElevated
                @unknown default:
                    placeholderHero
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous))
        } else {
            placeholderHero
        }
    }

    private var placeholderHero: some View {
        RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
            .fill(LumoColors.surfaceElevated)
            .frame(height: 140)
            .overlay(
                Image(systemName: card.categoryIcon.isEmpty ? "doc.text" : card.categoryIcon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(LumoColors.labelTertiary)
            )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.xs) {
            Text(readerStateArticle()?.title ?? card.title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(LumoColors.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reader.title")
            metaLine
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        let article = readerStateArticle()
        let byline = article?.byline
        let published = article?.publishedDate
        if byline != nil || published != nil {
            HStack(spacing: LumoSpacing.xs) {
                if let byline {
                    Text(byline)
                }
                if byline != nil && published != nil {
                    Text("·")
                }
                if let published {
                    Text(published)
                }
            }
            .font(LumoFonts.caption)
            .foregroundStyle(LumoColors.labelSecondary)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch controller.state {
        case .idle:
            EmptyView()
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.regular)
                Spacer()
            }
            .padding(.top, LumoSpacing.lg)
            .accessibilityIdentifier("reader.loading")
        case .ready(_, let article):
            ReaderArticleBody(article: article)
                .accessibilityIdentifier("reader.body")
        case .error(_, let error):
            VStack(alignment: .leading, spacing: LumoSpacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(LumoColors.warning)
                Text(error.errorDescription ?? "Couldn't load the article.")
                    .font(LumoFonts.body)
                    .foregroundStyle(LumoColors.label)
                Button {
                    if let url = URL(string: card.sourceURL) {
                        openURL(url)
                    }
                } label: {
                    Text("Open in Safari")
                        .font(LumoFonts.bodyEmphasized)
                        .foregroundStyle(.white)
                        .padding(.horizontal, LumoSpacing.md)
                        .padding(.vertical, LumoSpacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                                .fill(LumoColors.cyan)
                        )
                }
                .accessibilityIdentifier("reader.openInSafariFallback")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, LumoSpacing.md)
            .accessibilityIdentifier("reader.error")
        }
    }

    private func readerStateArticle() -> ReaderArticle? {
        if case .ready(_, let article) = controller.state { return article }
        return nil
    }
}
