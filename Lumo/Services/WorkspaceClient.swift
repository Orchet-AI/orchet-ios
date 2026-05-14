import Foundation

/// HTTP client for the `/workspace/*` aggregator endpoints owned by
/// svc-orchestrator. Mirrors the web `lib/workspace-client.ts` shape;
/// each method returns a strongly-typed envelope so the SwiftUI
/// layer can render source pills (`live` / `cached` / `stale` / `error`)
/// without poking at raw JSON.
///
/// Auth: gateway-direct when `gatewayBaseURL` is set, else apps/web BFF.
protocol WorkspaceFetching: AnyObject {
    func fetchToday() async throws -> WorkspaceTodayEnvelope
    func fetchOperations() async throws -> WorkspaceOperationsEnvelope
    func fetchMissions(limit: Int?) async throws -> [WorkspaceMission]
}

enum WorkspaceError: Error, Equatable {
    case unauthorized
    case transport(String)
    case decode
    case badStatus(Int)
}

// MARK: - Models

struct WorkspaceCardSource: Codable, Equatable {
    let source: String  // "live" | "cached" | "stale" | "error"
    let age_ms: Int?
    let error: String?
}

struct WorkspaceCalendarEvent: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let start_iso: String
    let end_iso: String?
    let location: String?
    let attendees_count: Int
    let source: String  // "google" | "microsoft"
}

struct WorkspaceCalendarCard: Codable, Equatable {
    let events: [WorkspaceCalendarEvent]
    let source: String
    let age_ms: Int?
    let error: String?
}

struct WorkspaceEmailPreview: Codable, Identifiable, Equatable {
    let id: String
    let from: String
    let subject: String
    let snippet: String
    let received_iso: String
    let source: String  // "gmail" | "outlook"
    let unread: Bool
}

struct WorkspaceEmailCard: Codable, Equatable {
    let messages: [WorkspaceEmailPreview]
    let source: String
    let age_ms: Int?
    let error: String?
}

struct WorkspaceSpotifyNowPlaying: Codable, Equatable {
    let is_playing: Bool
    let track_name: String?
    let artist: String?
    let album_art_url: String?
}

struct WorkspaceSpotifyCard: Codable, Equatable {
    let now_playing: WorkspaceSpotifyNowPlaying?
    let source: String
    let age_ms: Int?
    let error: String?
}

struct WorkspaceYouTubeVideo: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let views: Int?
    let published_at: String
    let thumbnail_url: String?
}

struct WorkspaceYouTubeChannel: Codable, Identifiable, Equatable {
    var id: String { channel_id }
    let channel_id: String
    let channel_title: String
    let recent_videos: [WorkspaceYouTubeVideo]
}

struct WorkspaceYouTubeCard: Codable, Equatable {
    let channels: [WorkspaceYouTubeChannel]
    let source: String
    let age_ms: Int?
    let error: String?
}

struct WorkspaceTodayEnvelope: Codable, Equatable {
    let generated_at: String
    let calendar: WorkspaceCalendarCard
    let email: WorkspaceEmailCard
    let spotify: WorkspaceSpotifyCard
    let youtube: WorkspaceYouTubeCard
}

struct WorkspaceConnectorRow: Codable, Identifiable, Equatable {
    var id: String { agent_id }
    let agent_id: String
    let display_name: String?
    let source: String?  // "oauth" | "system"
    let status: String  // "active" | "expired" | "revoked" | "error"
    let connected_at: String
    let last_used_at: String?
    let last_refreshed_at: String?
    let expires_at: String?
    let expires_in_seconds: Int?
    let scope_count: Int
}

struct WorkspaceAuditRow: Codable, Identifiable, Equatable {
    let id: Int
    let agent_id: String
    let action_type: String
    let ok: Bool
    let platform_response_code: Int?
    let content_excerpt: String?
    let created_at: String
    let origin: String
    let error_text: String?
}

struct WorkspaceCacheRow: Codable, Identifiable, Equatable {
    var id: String { agent_id }
    let agent_id: String
    let rows: Int
    let newest_fetched_at: String?
}

struct WorkspaceOperationsEnvelope: Codable, Equatable {
    let generated_at: String
    let connectors: [WorkspaceConnectorRow]
    let audit: [WorkspaceAuditRow]
    let cache: [WorkspaceCacheRow]
}

struct WorkspaceMission: Codable, Identifiable, Equatable {
    let id: String
    let title: String?
    let status: String?
    let created_at: String?
}

// MARK: - Live client

final class WorkspaceClient: WorkspaceFetching {
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

    func fetchToday() async throws -> WorkspaceTodayEnvelope {
        try await getJSON(path: "workspace/today")
    }

    func fetchOperations() async throws -> WorkspaceOperationsEnvelope {
        try await getJSON(path: "workspace/operations")
    }

    func fetchMissions(limit: Int? = nil) async throws -> [WorkspaceMission] {
        var path = "workspace/missions"
        if let limit { path += "?limit=\(limit)" }
        struct Wrapped: Decodable { let missions: [WorkspaceMission] }
        do {
            let wrapped: Wrapped = try await getJSON(path: path)
            return wrapped.missions
        } catch {
            // Some deploys return a bare array — fall through.
            return try await getJSON(path: path)
        }
    }

    private func endpoint(for path: String) -> URL {
        if let gw = gatewayBaseURL { return gw.appendingPathComponent(path) }
        return baseURL.appendingPathComponent("api/\(path)")
    }

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        var req = URLRequest(url: endpoint(for: path))
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
            throw WorkspaceError.transport("\(error)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw WorkspaceError.transport("non-http response")
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw WorkspaceError.decode
            }
        case 401:
            throw WorkspaceError.unauthorized
        default:
            throw WorkspaceError.badStatus(http.statusCode)
        }
    }
}
