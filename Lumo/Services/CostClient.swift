import Foundation

/// HTTP client for the `GET /cost/dashboard` endpoint owned by
/// svc-orchestrator. Mirrors the web `/settings/cost` data source —
/// budget caps, today + month totals, daily trend, top agents,
/// recent events. Same envelope shape as
/// `packages/domain-observability/src/cost.ts::UserCostDashboard`.
protocol CostFetching: AnyObject {
    func fetchDashboard() async throws -> UserCostDashboard
}

enum CostServiceError: Error, Equatable {
    case unauthorized
    case transport(String)
    case decode
    case badStatus(Int)
}

// MARK: - Models

struct UserCostDashboard: Codable, Equatable {
    let budget: CostBudget
    let today: SpendSummary
    let month: SpendSummary
    let daily: [DailyRow]
    let agents: [AgentRow]
    let recent: [RecentRow]
}

struct CostBudget: Codable, Equatable {
    let tier: String
    let dailyCapUsd: Double?
    let monthlyCapUsd: Double?
    let softCap: Bool
}

struct SpendSummary: Codable, Equatable {
    let window: String
    let windowStartAt: String
    let windowEndAt: String
    let costUsdTotal: Double
    let source: String
}

struct DailyRow: Codable, Equatable, Identifiable {
    let date: String
    let totalUsd: Double
    let invocations: Int
    var id: String { date }
}

struct AgentRow: Codable, Equatable, Identifiable {
    let agentId: String
    let totalUsd: Double
    let invocations: Int
    var id: String { agentId }
}

struct RecentRow: Codable, Equatable, Identifiable {
    let createdAt: String
    let agentId: String
    let capabilityId: String?
    let totalUsd: Double
    let status: String
    let modelUsed: String?
    var id: String { "\(createdAt)|\(agentId)|\(capabilityId ?? "")" }
}

// MARK: - Live client

final class CostClient: CostFetching {
    private let baseURL: URL
    private let gatewayBaseURL: URL?
    private let session: URLSession
    private let userIDProvider: () -> String?
    private let accessTokenProvider: () -> String?

    init(
        baseURL: URL,
        gatewayBaseURL: URL? = nil,
        userIDProvider: @escaping () -> String?,
        accessTokenProvider: @escaping () -> String? = { nil },
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.gatewayBaseURL = gatewayBaseURL
        self.userIDProvider = userIDProvider
        self.accessTokenProvider = accessTokenProvider
        self.session = session
    }

    func fetchDashboard() async throws -> UserCostDashboard {
        let endpoint: URL
        if let gw = gatewayBaseURL {
            endpoint = gw.appendingPathComponent("cost/dashboard")
        } else {
            endpoint = baseURL.appendingPathComponent("api/cost/dashboard")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userID = userIDProvider(), !userID.isEmpty {
            req.setValue(userID, forHTTPHeaderField: "x-orchet-user-id")
            req.setValue(userID, forHTTPHeaderField: "x-lumo-user-id")
        }
        if let token = accessTokenProvider(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw CostServiceError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw CostServiceError.transport("non-http response")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(UserCostDashboard.self, from: data)
            } catch {
                throw CostServiceError.decode
            }
        case 401:
            throw CostServiceError.unauthorized
        default:
            throw CostServiceError.badStatus(http.statusCode)
        }
    }
}
