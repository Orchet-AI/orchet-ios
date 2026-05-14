import Foundation

/// HTTP client for the GET /reader endpoint owned by svc-orchestrator.
///
/// Gateway-direct when configured (matches the route-table prefix
/// `/reader` → orchestrator/`/reader`), else apps/web BFF fallback
/// for parity with the other clients during the strangler rollout.
protocol ReaderFetching: AnyObject {
    func fetchArticle(url: String) async throws -> ReaderArticle
}

enum ReaderServiceError: Error, LocalizedError, Equatable {
    case timeout
    case fetchFailed
    case parseFailed
    case blockedURL
    case transport(String)
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .timeout: return "The article took too long to load."
        case .fetchFailed: return "Couldn't reach the article source."
        case .parseFailed: return "The article didn't have readable content."
        case .blockedURL: return "That link is blocked."
        case .transport(let detail): return "Network error: \(detail)"
        case .badStatus(let code): return "Server returned HTTP \(code)."
        }
    }
}

final class ReaderService: ReaderFetching {
    private let baseURL: URL
    private let gatewayBaseURL: URL?
    private let session: URLSession
    private let userIDProvider: () -> String?
    private let accessTokenProvider: () -> String?

    init(
        baseURL: URL,
        gatewayBaseURL: URL? = nil,
        userIDProvider: @escaping () -> String? = { nil },
        accessTokenProvider: @escaping () -> String? = { nil },
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.gatewayBaseURL = gatewayBaseURL
        self.userIDProvider = userIDProvider
        self.accessTokenProvider = accessTokenProvider
        self.session = session
    }

    static func makeFromBundle(
        _ bundle: Bundle = .main,
        userIDProvider: @escaping () -> String? = { nil },
        accessTokenProvider: @escaping () -> String? = { nil }
    ) -> ReaderService? {
        let raw = bundle.object(forInfoDictionaryKey: "LumoAPIBase") as? String ?? "http://localhost:3000"
        guard let url = URL(string: raw) else { return nil }
        let gatewayRaw = bundle.object(forInfoDictionaryKey: "OrchetGatewayBase") as? String ?? ""
        let gatewayURL: URL? = !gatewayRaw.isEmpty ? URL(string: gatewayRaw) : nil
        return ReaderService(
            baseURL: url,
            gatewayBaseURL: gatewayURL,
            userIDProvider: userIDProvider,
            accessTokenProvider: accessTokenProvider
        )
    }

    func fetchArticle(url: String) async throws -> ReaderArticle {
        guard !url.isEmpty else { throw ReaderServiceError.blockedURL }
        guard let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw ReaderServiceError.blockedURL
        }

        let endpoint: URL
        if let gw = gatewayBaseURL {
            endpoint = gw.appendingPathComponent("reader")
        } else {
            // Backend route is /reader on the orchestrator; apps/web
            // mirrored it under /api/reader during the strangler.
            endpoint = baseURL.appendingPathComponent("api/reader")
        }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "url", value: url)]
        var request = URLRequest(url: components.url ?? endpoint)
        _ = encoded // silence — only used to validate encodability
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8.0
        if let userID = userIDProvider(), !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "x-orchet-user-id")
            request.setValue(userID, forHTTPHeaderField: "x-lumo-user-id")
        }
        if let token = accessTokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlErr as URLError where urlErr.code == .timedOut {
            throw ReaderServiceError.timeout
        } catch {
            throw ReaderServiceError.transport(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ReaderServiceError.transport("non-http response")
        }
        switch http.statusCode {
        case 200..<300:
            let parsed = try JSONDecoder().decode(ReaderResponse.self, from: data)
            if let article = parsed.article, parsed.ok {
                return article
            }
            // 200 with ok=false — map the code to the error.
            throw map(code: parsed.code)
        case 400:
            // Validator rejected the URL (private host, internal host,
            // bad scheme). Surfaced as blocked_url server-side.
            throw ReaderServiceError.blockedURL
        case 504:
            throw ReaderServiceError.timeout
        case 502:
            // The server returns 502 for fetch_failed / parse_failed —
            // try the JSON body to pick the right variant.
            if let parsed = try? JSONDecoder().decode(ReaderResponse.self, from: data) {
                throw map(code: parsed.code)
            }
            throw ReaderServiceError.fetchFailed
        default:
            throw ReaderServiceError.badStatus(http.statusCode)
        }
    }

    private func map(code: String?) -> ReaderServiceError {
        switch code ?? "" {
        case "timeout": return .timeout
        case "fetch_failed": return .fetchFailed
        case "parse_failed": return .parseFailed
        case "blocked_url": return .blockedURL
        default: return .fetchFailed
        }
    }
}
