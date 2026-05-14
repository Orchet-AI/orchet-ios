import Foundation
import GoogleSignIn
import UIKit

/// Native Google Sign-In wrapper. Returns the OIDC `idToken` string
/// that Supabase's `signInWithIdToken` expects.
///
/// We added this in response to the Supabase web OAuth flow failing
/// on iOS: the project's `/callback` was redirecting to `www.orchet.ai`
/// (SITE_URL) instead of the custom-scheme `lumo://auth/callback` we
/// requested, and the web shell there then raced a /token exchange
/// without an iOS-side PKCE verifier. Native sign-in sidesteps the
/// entire redirect chain.
@MainActor
enum GoogleNativeSignIn {
    enum Error: Swift.Error, LocalizedError {
        case notConfigured
        case missingClientID
        case missingPresenter
        case missingIDToken
        case underlying(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Google sign-in is not configured."
            case .missingClientID:
                return "Google CLIENT_ID is missing from the bundle."
            case .missingPresenter:
                return "Couldn't find a window to present the Google sign-in sheet."
            case .missingIDToken:
                return "Google didn't return an identity token."
            case .underlying(let detail):
                return detail
            }
        }
    }

    /// Run the native sign-in sheet, return the idToken string.
    static func idToken() async throws -> String {
        let clientID = try readClientID()
        if GIDSignIn.sharedInstance.configuration == nil {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        guard let presenter = topMostViewController() else {
            throw Error.missingPresenter
        }
        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch {
            throw Error.underlying(String(describing: error))
        }
        guard let token = result.user.idToken?.tokenString else {
            throw Error.missingIDToken
        }
        return token
    }

    // MARK: - Helpers

    private static func readClientID() throws -> String {
        // The Google OAuth client plist is bundled at the root of the
        // Resources tree as
        // `client_<client_id>.apps.googleusercontent.com.plist`. We
        // read CLIENT_ID from the first such file we find at runtime
        // so the value isn't duplicated into xcconfig.
        let bundle = Bundle.main
        if let url = bundle.urls(forResourcesWithExtension: "plist", subdirectory: nil)?
            .first(where: { $0.lastPathComponent.hasPrefix("client_") && $0.lastPathComponent.hasSuffix(".apps.googleusercontent.com.plist") }),
           let dict = NSDictionary(contentsOf: url),
           let clientID = dict["CLIENT_ID"] as? String,
           !clientID.isEmpty {
            return clientID
        }
        throw Error.missingClientID
    }

    private static func topMostViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: { $0.isKeyWindow })
            ?? scene?.windows.first
        else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
