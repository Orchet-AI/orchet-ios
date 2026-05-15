import Foundation

/// SSE frame value the orchestrator emits when a tool dispatch
/// returns `connection_required` and the backend successfully minted
/// an OAuth 2.1 authorize URL. The chat surface renders a
/// `ConnectionRequestCardView` that opens the URL via
/// `ASWebAuthenticationSession`.
///
/// Mirrors the backend wire shape exactly — see orchet-backend
/// `packages/domain-orchestrator/src/executor/connection-required.ts`.
/// Keep snake_case property names so the Codable round-trip is
/// drop-in for the SSE decoder.
struct ConnectionRequiredFrameValue: Codable, Equatable {
    /// Marketplace agent_id (e.g. "google", "lumo_rentals").
    let agent_id: String
    /// Human-readable label for the card header.
    let display_name: String
    /// Pre-minted OAuth 2.1 authorize URL. Carries PKCE challenge,
    /// state, scopes, and redirect_uri. iOS hands it straight to
    /// ASWebAuthenticationSession.
    let authorize_url: String
    /// The tool the dispatcher rejected. Surfaced as context in the
    /// card body so the user knows WHY they're being asked to connect.
    let blocked_tool: String
}

extension ConnectionRequiredFrameValue {
    /// Shape guard mirroring the web `isConnectionRequiredFrameValue`.
    /// A malformed frame (network glitch, schema drift, replay row
    /// with a stale shape) returns false → caller drops the card,
    /// chat surface keeps working.
    var isRenderable: Bool {
        !agent_id.isEmpty
            && !display_name.isEmpty
            && !blocked_tool.isEmpty
            && URL(string: authorize_url) != nil
            && (authorize_url.hasPrefix("https://") || authorize_url.hasPrefix("http://"))
    }
}
