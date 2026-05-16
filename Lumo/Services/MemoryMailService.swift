import Foundation

/// MemoryMailService — Phase C of ORCHET-IOS-MEMORY-LEARNING.
///
/// Backs the iOS Settings → Memory Sources → Mail toggle by talking
/// to three orchestrator routes:
///
///   GET   /memory/sources/mail      → { enabled }
///   PATCH /memory/sources/mail      → { ok, enabled }
///   POST  /memory/mail/forget       → { ok, deleted }
///
/// Unlike Calendar (which is local-state-only on `MemorySourcesSettings`),
/// the Mail opt-in is **server-side** state on
/// `user_profile.mail_memory_enabled`. The cron reads that flag to
/// decide which users to scan; this service is the iOS surface
/// flipping it.
///
/// Auth: same gateway plumbing as `CalendarSignalService` —
/// `Bearer` + `x-orchet-user-id` header. Gateway prefix-routes
/// `/memory` → orchestrator.
///
/// Errors collapse to a small enum so the UI can show a single
/// "couldn't reach Orchet" toast without leaking transport
/// internals.
@MainActor
final class MemoryMailService {
    static let shared = MemoryMailService()

    private var session: URLSession = .shared
    private var gatewayBaseURL: URL?
    private var userIDProvider: () -> String? = { nil }
    private var accessTokenProvider: () -> String? = { nil }

    init() {}

    /// Configure from app boot. Mirrors `CalendarSignalService.configure`.
    func configure(
        gatewayBaseURL: URL?,
        userIDProvider: @escaping () -> String?,
        accessTokenProvider: @escaping () -> String?,
        session: URLSession = .shared
    ) {
        self.gatewayBaseURL = gatewayBaseURL
        self.userIDProvider = userIDProvider
        self.accessTokenProvider = accessTokenProvider
        self.session = session
    }

    /// GET /memory/sources/mail — returns the current server flag.
    /// Nil on unconfigured (no base URL / no auth) so the UI can keep
    /// showing the toggle as off without crashing.
    func fetchEnabled() async -> Bool? {
        guard let req = makeRequest(method: "GET", path: "memory/sources/mail") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(EnabledResponse.self, from: data)
            return decoded.enabled
        } catch {
            return nil
        }
    }

    /// PATCH /memory/sources/mail — flip the server flag.
    /// Returns true on success; false on any transport/auth failure
    /// so the UI can roll its local toggle back.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard var req = makeRequest(method: "PATCH", path: "memory/sources/mail") else {
            return false
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["enabled": enabled]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    /// POST /memory/mail/forget — wipe the per-message audit rows.
    /// Derived facts persist per ADR-014; the user clears those via
    /// the existing `/memory/facts` surface.
    @discardableResult
    func forgetEverything() async -> Bool {
        guard let req = makeRequest(method: "POST", path: "memory/mail/forget") else {
            return false
        }
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func makeRequest(method: String, path: String) -> URLRequest? {
        guard let base = gatewayBaseURL,
              let token = accessTokenProvider(),
              !token.isEmpty,
              let userId = userIDProvider(),
              !userId.isEmpty
        else { return nil }
        let url = base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userId, forHTTPHeaderField: "x-orchet-user-id")
        return req
    }

    private struct EnabledResponse: Decodable {
        let enabled: Bool
    }
}
