import XCTest
@testable import Lumo

/// ORCHET-IOS-PARITY-1B — verify the html→md transform that feeds
/// `ReaderArticleBody`'s `AttributedString(markdown:)`. Pure helper
/// so the conversion is unit-testable without a live render.
final class ReaderArticleBodyTests: XCTestCase {

    func test_paragraphs_becomeBlankLineSeparated() {
        let md = ReaderArticleBody.htmlToMarkdown("<p>First.</p><p>Second.</p>")
        XCTAssertEqual(md, "First.\n\nSecond.")
    }

    func test_strong_and_em_mapToMarkdownEmphasis() {
        let md = ReaderArticleBody.htmlToMarkdown("<p><strong>Bold</strong> and <em>italic</em>.</p>")
        XCTAssertEqual(md, "**Bold** and *italic*.")
    }

    func test_anchors_mapToInlineLinks() {
        let html = #"<p>See <a href="https://orchet.ai/x">Orchet</a> for more.</p>"#
        let md = ReaderArticleBody.htmlToMarkdown(html)
        XCTAssertEqual(md, "See [Orchet](https://orchet.ai/x) for more.")
    }

    func test_headings_mapToHashes() {
        let md = ReaderArticleBody.htmlToMarkdown("<h1>Title</h1><h3>Sub</h3>")
        XCTAssertEqual(md, "# Title\n\n### Sub")
    }

    func test_listItems_becomeDashBullets() {
        let md = ReaderArticleBody.htmlToMarkdown("<ul><li>One</li><li>Two</li></ul>")
        XCTAssertEqual(md, "- One\n- Two")
    }

    func test_scriptAndStyle_areStrippedWholesale() {
        let html = "<script>alert(1)</script><p>Visible</p><style>p{color:red}</style>"
        let md = ReaderArticleBody.htmlToMarkdown(html)
        XCTAssertEqual(md, "Visible")
    }

    func test_brTags_becomeNewlines() {
        let md = ReaderArticleBody.htmlToMarkdown("<p>Line one<br>Line two</p>")
        // <br> → newline; the surrounding <p> still adds its own \n\n.
        XCTAssertTrue(md.contains("Line one\nLine two"))
    }

    func test_entities_decode() {
        let md = ReaderArticleBody.htmlToMarkdown("<p>Tom &amp; Jerry &mdash; &quot;mice&quot;.</p>")
        // We only decode the common five; &mdash; is left untouched.
        XCTAssertEqual(md, "Tom & Jerry &mdash; \"mice\".")
    }

    func test_attributedString_buildsForKnownGoodMarkup() {
        let attributed = ReaderArticleBody.attributedFromHTML(
            "<p>Hi <strong>there</strong>.</p>"
        )
        XCTAssertNotNil(attributed)
        if let attributed {
            let rendered = String(attributed.characters)
            XCTAssertTrue(rendered.contains("there"))
        }
    }
}
