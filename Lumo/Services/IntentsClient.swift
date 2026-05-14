import Foundation

/// HTTP client for the `/intents` CRUD endpoints owned by
/// svc-orchestrator. Mirrors the web `/intents` page
/// (`apps/web/app/intents/page.tsx`) — list, toggle enabled, delete.
///
/// Creation is intentionally minimal in the iOS UI today (description
/// + cron + timezone); the richer schedule builder is a future pass.
protocol IntentsFetching: AnyObject {
    func listIntents() async throws -> [StandingIntent]
    func setEnabled(id: String, enabled: Bool) async throws -> StandingIntent
    func deleteIntent(id: String) async throws
    func createIntent(
        description: String,
        schedule_cron: String,
        timezone: String
    ) async throws -> StandingIntent
}

enum IntentsServiceError: Error, Equatable {
    case unauthorized
    case transport(String)
    case decode
    case badStatus(Int)
    case validation(String)
}

// MARK: - Wire shape

/// Mirrors orchet-backend
/// `packages/domain-autonomy/src/standing-intents/types.ts`.
struct StandingIntent: Codable, Equatable, Identifiable {
    let id: String
    let user_id: String
    let description: String
    let schedule_cron: String
    let timezone: String
    let enabled: Bool
    let last_fired_at: String?
    let next_fire_at: String?
    let created_at: String
    let updated_at: String
}

/// Error envelope shape from the orchestrator's 400 responses.
private struct IntentsErrorBody: Decodable {
    let error: String?
    let detail: String?
}

// MARK: - Live client

final class IntentsClient: IntentsFetching {
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

    func listIntents() async throws -> [StandingIntent] {
        struct Wrapped: Decodable { let intents: [StandingIntent] }
        let wrapped: Wrapped = try await execute(method: "GET", path: "intents", body: nil)
        return wrapped.intents
    }

    func setEnabled(id: String, enabled: Bool) async throws -> StandingIntent {
        struct Wrapped: Decodable { let intent: StandingIntent }
        let body: [String: Any] = ["enabled": enabled]
        let wrapped: Wrapped = try await execute(method: "PATCH", path: "intents/\(id)", body: body)
        return wrapped.intent
    }

    func deleteIntent(id: String) async throws {
        struct Ack: Decodable { let ok: Bool }
        let _: Ack = try await execute(method: "DELETE", path: "intents/\(id)", body: nil)
    }

    func createIntent(
        description: String,
        schedule_cron: String,
        timezone: String
    ) async throws -> StandingIntent {
        struct Wrapped: Decodable { let intent: StandingIntent }
        let body: [String: Any] = [
            "description": description,
            "schedule_cron": schedule_cron,
            "timezone": timezone,
        ]
        let wrapped: Wrapped = try await execute(method: "POST", path: "intents", body: body)
        return wrapped.intent
    }

    // MARK: - Internals

    private func execute<T: Decodable>(
        method: String,
        path: String,
        body: [String: Any]?
    ) async throws -> T {
        let endpoint: URL
        if let gw = gatewayBaseURL {
            endpoint = gw.appendingPathComponent(path)
        } else {
            endpoint = baseURL.appendingPathComponent("api/\(path)")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let userID = userIDProvider(), !userID.isEmpty {
            req.setValue(userID, forHTTPHeaderField: "x-orchet-user-id")
            req.setValue(userID, forHTTPHeaderField: "x-lumo-user-id")
        }
        if let token = accessTokenProvider(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw IntentsServiceError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw IntentsServiceError.transport("non-http response")
        }
        switch http.statusCode {
        case 200..<300:
            // DELETE returns {ok: true} which decodes to Ack; the
            // type-erased decode handles both Ack and the wrapped
            // shapes.
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw IntentsServiceError.decode
            }
        case 401:
            throw IntentsServiceError.unauthorized
        case 400:
            if let parsed = try? JSONDecoder().decode(IntentsErrorBody.self, from: data) {
                throw IntentsServiceError.validation(parsed.detail ?? parsed.error ?? "Invalid request.")
            }
            throw IntentsServiceError.badStatus(400)
        default:
            throw IntentsServiceError.badStatus(http.statusCode)
        }
    }
}
