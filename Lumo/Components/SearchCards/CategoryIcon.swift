import SwiftUI

/// Maps the server's `category_icon` string to an SF Symbol name.
///
/// The server's vocabulary (categoryIcon enum in
/// `orchet-backend/packages/domain-orchestrator/src/executor/
/// search-cards.ts`) is small and stable. Unknown values fall through
/// to `globe` so a future server addition doesn't render a missing-
/// icon hole.
///
/// SF Symbol choices match the Lucide icons web uses by visual
/// equivalence — not pixel-identical, but the symbol set is well-
/// covered enough to keep the brand consistent.
enum SearchCardSymbol {
    static func sfName(for categoryIcon: String) -> String {
        switch categoryIcon {
        case "sparkles":
            return "sparkles"
        case "device-laptop":
            return "laptopcomputer"
        case "map-2":
            return "map"
        case "chart-line":
            return "chart.line.uptrend.xyaxis"
        case "ball-football":
            return "soccerball"
        case "cloud":
            return "cloud"
        case "music":
            return "music.note"
        case "news":
            return "newspaper"
        case "building-bank":
            return "building.columns"
        case "briefcase":
            return "briefcase"
        case "code":
            return "chevron.left.forwardslash.chevron.right"
        case "world":
            return "globe"
        default:
            return "globe"
        }
    }
}

/// Reusable view: render a search-card category icon at the given
/// size using the theme's icon color. Used by both the featured card
/// (large) and the compact card (small thumbnail).
struct CategoryIconView: View {
    let categoryIcon: String
    let theme: SearchCardTheme
    let size: CGFloat

    var body: some View {
        Image(systemName: SearchCardSymbol.sfName(for: categoryIcon))
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(theme.icon)
            .accessibilityHidden(true)
    }
}
