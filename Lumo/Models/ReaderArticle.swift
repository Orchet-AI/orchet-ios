import Foundation

/// Reader-mode article envelope returned by GET /reader.
///
/// Canonical contract — orchet-backend
/// `services/orchestrator/src/routes/reader.ts::parseReadability`.
/// Snake-cased JSON keys mapped via `CodingKeys`.
struct ReaderArticle: Codable, Equatable {
    let title: String
    let byline: String?
    let leadImageURL: String?
    let contentHTML: String
    let contentText: String
    let sourceHost: String
    let sourceURL: String
    let excerpt: String?
    let publishedDate: String?

    enum CodingKeys: String, CodingKey {
        case title
        case byline
        case leadImageURL = "lead_image_url"
        case contentHTML = "content_html"
        case contentText = "content_text"
        case sourceHost = "source_host"
        case sourceURL = "source_url"
        case excerpt
        case publishedDate = "published_date"
    }
}

/// Top-level envelope. The `ok=false` shape carries a `code`
/// matching the server's error taxonomy.
struct ReaderResponse: Decodable {
    let ok: Bool
    let article: ReaderArticle?
    let code: String?
}
