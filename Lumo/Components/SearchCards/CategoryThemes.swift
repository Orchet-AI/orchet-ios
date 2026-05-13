import SwiftUI

/// Per-category color theme for `SearchResultCard` hero blocks +
/// category chips. Hex values MUST match
/// `orchet-web/lib/search-cards-core.ts` `SEARCH_CARD_CATEGORY_THEME`
/// exactly — that file is the canonical source of truth so web and
/// iOS render the same color for the same category. Diverging is a
/// brand bug.
///
/// Each entry pairs a lightest-stop background (50) with a mid-stop
/// icon color (600) plus a darkest-stop chip background (900) with
/// the matching lightest-stop chip text. Categories the server hasn't
/// learned yet fall through to "World" (neutral gray).
struct SearchCardTheme: Hashable {
    let background: Color
    let icon: Color
    let chipBackground: Color
    let chipText: Color
}

enum SearchCardCategoryTheme {
    static let themes: [String: SearchCardTheme] = [
        "AI": SearchCardTheme(
            background: Color(hex: 0xE6F1FB),
            icon: Color(hex: 0x185FA5),
            chipBackground: Color(hex: 0x042C53),
            chipText: Color(hex: 0xE6F1FB)
        ),
        "Hardware": SearchCardTheme(
            background: Color(hex: 0xEEEDFE),
            icon: Color(hex: 0x534AB7),
            chipBackground: Color(hex: 0x26215C),
            chipText: Color(hex: 0xEEEDFE)
        ),
        "Maps": SearchCardTheme(
            background: Color(hex: 0xE1F5EE),
            icon: Color(hex: 0x0F6E56),
            chipBackground: Color(hex: 0x04342C),
            chipText: Color(hex: 0xE1F5EE)
        ),
        "Finance": SearchCardTheme(
            background: Color(hex: 0xFAEEDA),
            icon: Color(hex: 0x854F0B),
            chipBackground: Color(hex: 0x412402),
            chipText: Color(hex: 0xFAEEDA)
        ),
        "Sports": SearchCardTheme(
            background: Color(hex: 0xFAECE7),
            icon: Color(hex: 0x993C1D),
            chipBackground: Color(hex: 0x4A1B0C),
            chipText: Color(hex: 0xFAECE7)
        ),
        "Weather": SearchCardTheme(
            background: Color(hex: 0xE6F1FB),
            icon: Color(hex: 0x185FA5),
            chipBackground: Color(hex: 0x042C53),
            chipText: Color(hex: 0xE6F1FB)
        ),
        "Music": SearchCardTheme(
            background: Color(hex: 0xFBEAF0),
            icon: Color(hex: 0x993556),
            chipBackground: Color(hex: 0x4B1528),
            chipText: Color(hex: 0xFBEAF0)
        ),
        "News": SearchCardTheme(
            background: Color(hex: 0xF1EFE8),
            icon: Color(hex: 0x5F5E5A),
            chipBackground: Color(hex: 0x2C2C2A),
            chipText: Color(hex: 0xF1EFE8)
        ),
        "Business": SearchCardTheme(
            background: Color(hex: 0xEAF3DE),
            icon: Color(hex: 0x3B6D11),
            chipBackground: Color(hex: 0x173404),
            chipText: Color(hex: 0xEAF3DE)
        ),
        "Science": SearchCardTheme(
            background: Color(hex: 0xEEEDFE),
            icon: Color(hex: 0x534AB7),
            chipBackground: Color(hex: 0x26215C),
            chipText: Color(hex: 0xEEEDFE)
        ),
        "Travel": SearchCardTheme(
            background: Color(hex: 0xE1F5EE),
            icon: Color(hex: 0x0F6E56),
            chipBackground: Color(hex: 0x04342C),
            chipText: Color(hex: 0xE1F5EE)
        ),
        "World": SearchCardTheme(
            background: Color(hex: 0xF1EFE8),
            icon: Color(hex: 0x5F5E5A),
            chipBackground: Color(hex: 0x2C2C2A),
            chipText: Color(hex: 0xF1EFE8)
        ),
    ]

    static let fallback = themes["World"]!

    static func theme(for category: String) -> SearchCardTheme {
        themes[category] ?? fallback
    }
}

private extension Color {
    /// Construct a `Color` from a 0xRRGGBB integer. Pure convenience —
    /// matches the hex literals in the brand color spec without
    /// hand-converting to 0-1 floats. Alpha is fixed at 1.0.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
