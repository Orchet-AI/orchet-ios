import Foundation
import SwiftUI

/// Converts the reader-mode `content_html` into a SwiftUI body. The
/// renderer prefers `AttributedString(markdown:)` after a tiny
/// regex-based html→md transform — that keeps headings, links, and
/// emphasis without dragging in `WKWebView`. If conversion fails, we
/// fall back to plain prose.
struct ReaderArticleBody: View {
    let article: ReaderArticle

    var body: some View {
        if let attributed = Self.attributedFromHTML(article.contentHTML) {
            Text(attributed)
                .font(LumoFonts.body)
                .foregroundStyle(LumoColors.label)
                .lineSpacing(4)
                .textSelection(.enabled)
        } else {
            Text(article.contentText)
                .font(LumoFonts.body)
                .foregroundStyle(LumoColors.label)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    /// Pure helper — exposed for tests.
    static func attributedFromHTML(_ html: String) -> AttributedString? {
        let md = htmlToMarkdown(html)
        return try? AttributedString(
            markdown: md,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    /// Lossy html → markdown for the reader's article body. Goals:
    ///   - Drop chrome tags (script/style/figure captions).
    ///   - Preserve paragraph breaks (each `<p>` → blank line).
    ///   - Preserve headings (`<h1..h6>` → `#`).
    ///   - Preserve emphasis (`<strong>` → `**`, `<em>` → `*`).
    ///   - Preserve inline links (`<a href>` → `[text](url)`).
    ///   - Drop everything else as plain text (Readability already
    ///     stripped most semantic noise).
    static func htmlToMarkdown(_ html: String) -> String {
        var s = html
        // Strip <script> and <style> blocks wholesale.
        s = s.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "<style[^>]*>.*?</style>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // <a href="…">x</a> → [x](href). Greedy enough for typical
        // Readability output; defensive against quoted href forms.
        s = s.replacingOccurrences(
            of: #"<a[^>]*href=['"]([^'"]+)['"][^>]*>(.*?)</a>"#,
            with: "[$2]($1)",
            options: [.regularExpression, .caseInsensitive]
        )
        // <strong>x</strong> → **x**, <b>x</b> → **x**.
        for tag in ["strong", "b"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>(.*?)</\(tag)>",
                with: "**$1**",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // <em>x</em> → *x*, <i>x</i> → *x*.
        for tag in ["em", "i"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>(.*?)</\(tag)>",
                with: "*$1*",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // <h1..h6>x</h1..h6> → `# x` then a blank line.
        for level in (1...6).reversed() {
            let hashes = String(repeating: "#", count: level)
            s = s.replacingOccurrences(
                of: "<h\(level)[^>]*>(.*?)</h\(level)>",
                with: "\(hashes) $1\n\n",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        // <li>x</li> → "- x" (one bullet per line, no nested-list
        // handling — Readability output rarely uses deep nesting).
        s = s.replacingOccurrences(
            of: "<li[^>]*>(.*?)</li>",
            with: "- $1\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // <br> → newline.
        s = s.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // <p>x</p> → "x\n\n".
        s = s.replacingOccurrences(
            of: "<p[^>]*>(.*?)</p>",
            with: "$1\n\n",
            options: [.regularExpression, .caseInsensitive]
        )
        // Drop anything else still tagged.
        s = s.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: [.regularExpression]
        )
        // Decode the four common HTML entities; the others are rare
        // enough in Readability output to be tolerable as-is.
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Collapse runs of more than two newlines.
        s = s.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: [.regularExpression]
        )
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
