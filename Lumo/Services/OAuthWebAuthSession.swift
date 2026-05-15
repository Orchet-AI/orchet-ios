import AuthenticationServices
import UIKit

/// Thin async wrapper over `ASWebAuthenticationSession` for the
/// inline-connect flow (PARITY-1D).
///
/// The orchestrator hands us a pre-minted OAuth authorize URL.
/// We open it in the system OAuth surface (shares cookies with
/// Safari, returns the final URL to a registered callback scheme).
/// On the callback we just resolve with `.success` — the backend's
/// `agent_connections` row is the source of truth for whether the
/// connect actually landed; the auto-retry follow-up turn will
/// surface any failure as a fresh `connection_required` frame.
///
/// Lives in a class because `ASWebAuthenticationSession` requires a
/// strong reference to its presentation-context provider for the
/// whole session lifetime.
@MainActor
final class OAuthWebAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum OAuthResult: Equatable {
        case success
        case canceled
        case error(String)
    }

    private var session: ASWebAuthenticationSession?

    /// Start a session against `authorizeURL`. Resolves when the
    /// callback URL matching `callbackScheme` is reached OR the user
    /// dismisses the sheet. `prefersEphemeralWebBrowserSession` is
    /// false on purpose — we want the user's existing Safari Google
    /// session to be reused so they don't have to re-enter
    /// credentials, and the provider's refresh token lifecycle
    /// benefits from the persistent session.
    func start(authorizeURL: URL, callbackScheme: String) async -> OAuthResult {
        await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { _, error in
                if let error = error as? ASWebAuthenticationSessionError {
                    switch error.code {
                    case .canceledLogin:
                        continuation.resume(returning: .canceled)
                    default:
                        continuation.resume(returning: .error(error.localizedDescription))
                    }
                    return
                }
                if let error {
                    continuation.resume(returning: .error(error.localizedDescription))
                    return
                }
                // Completion fired with a callback URL — the user
                // finished. The exact URL isn't useful here; the
                // backend already wrote the agent_connections row
                // via the OAuth provider redirect.
                continuation.resume(returning: .success)
            }
            session.prefersEphemeralWebBrowserSession = false
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(returning: .error("Couldn't start sign-in. Try again."))
            }
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(
        for _: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        // Pick the foreground key window; falls back to a blank
        // anchor on the rare case there isn't one (e.g. background
        // launch). ASWebAuthenticationSession degrades gracefully.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
