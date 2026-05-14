import Auth
import Foundation
import Supabase

/// Coarse auth lifecycle visible to the UI. The view tree picks AuthView
/// vs BiometricGateView vs RootView from this single value.
enum AuthState: Equatable {
    /// First-launch or signed-out. Show AuthView.
    case signedOut
    /// Apple Sign-In flow in progress.
    case signingIn
    /// Session restored from Keychain on cold-launch but biometric gate
    /// not yet satisfied this session.
    case needsBiometric(LumoUser)
    /// Fully authenticated and unlocked.
    case signedIn(LumoUser)

    var isAuthenticated: Bool {
        switch self {
        case .signedIn: return true
        default: return false
        }
    }

    /// The user ID associated with the current state, if there is one.
    /// Available across `.signedIn` and `.needsBiometric` (the user
    /// row is known but the biometric gate hasn't unlocked yet).
    var userID: String? {
        switch self {
        case .signedIn(let user), .needsBiometric(let user):
            return user.id
        case .signedOut, .signingIn:
            return nil
        }
    }
}

struct LumoUser: Equatable {
    let id: String
    let email: String?
    let displayName: String?

    /// Either the display name or the email-prefix as a fallback.
    var nameOrEmailPrefix: String {
        if let name = displayName, !name.isEmpty { return name }
        if let email, let prefix = email.split(separator: "@").first { return String(prefix) }
        return "\(Brand.name) user"
    }
}

/// Protocol on AuthService so AuthStateMachine can be tested with a
/// scripted fake instead of a real Supabase round-trip.
///
/// `@MainActor`-bound: every conformer (`AuthService`, `FakeAuthService`)
/// and every consumer (`AuthViewModel`, `AppRootView`) is already
/// main-actor-isolated. The annotation makes the contract explicit
/// and lets Swift 6 strict-concurrency mode accept the conformances
/// without `@preconcurrency` or other escape hatches.
@MainActor
protocol AuthServicing: AnyObject {
    var state: AuthState { get }
    var stateChange: AsyncStream<AuthState> { get }

    /// Supabase session JWT for the current user, or nil if signed out.
    /// Backend route handlers honor `Authorization: Bearer <token>` the
    /// same way they honor the browser's Supabase cookie — wiring this
    /// into HTTP clients is how iOS authenticates against Vercel.
    func currentAccessToken() -> String?

    /// Restore a session from Keychain on cold-launch. Resolves to
    /// either `signedOut` (no session), `needsBiometric(...)` (session
    /// found, biometric required), or `signedIn(...)` (session found,
    /// biometric not required or already unlocked).
    func restoreSession() async

    /// Exchange an Apple identity token + raw nonce for a Supabase
    /// session and transition to `signedIn`.
    func signInWithApple(_ credential: AppleCredential) async throws

    /// Run the Google OAuth flow via ASWebAuthenticationSession against
    /// Supabase's /authorize endpoint, exchange the returned code for
    /// a session, and transition to `signedIn`.
    func signInWithGoogle() async throws

    /// Pass the post-cold-launch biometric gate. If not currently in
    /// `needsBiometric`, no-op.
    func unlockWithBiometric() async throws

    /// Sign out and clear the Keychain session.
    func signOut() async

    /// `#if DEBUG` simulator-only path: synthesise a local user for
    /// screenshot capture without round-tripping to Apple/Supabase.
    func devSignIn() async
}

/// Real implementation backed by Supabase. The class is `@MainActor`
/// so all `@Published`-style state mutation happens on the main run
/// loop without explicit dispatch.
@MainActor
final class AuthService: AuthServicing {
    private(set) var state: AuthState = .signedOut {
        didSet {
            if oldValue != state { stateContinuation?.yield(state) }
        }
    }

    let stateChange: AsyncStream<AuthState>
    private var stateContinuation: AsyncStream<AuthState>.Continuation?

    private let config: AppConfig
    private let biometric: BiometricUnlockServicing
    private let isBiometricGateEnabled: () -> Bool
    /// Built lazily on first Google sign-in to avoid spinning up a
    /// presentation-context provider for users who never tap the
    /// Google button. Test path injects a fake via init.
    private var google: GoogleSignInServicing

    /// Supabase client is lazy-constructed on first use rather than at
    /// AuthService.init. Keeps cold-start fast on the common path
    /// (first-launch, no stored session) — the SDK's eager
    /// initialisation accounts for ~250 ms of launch time on iPhone 17
    /// in our measurement, and the user can't tap "Continue with
    /// Apple" until first frame anyway.
    private var _client: SupabaseClient?
    private var client: SupabaseClient? {
        if let _client { return _client }
        guard let url = config.supabaseURL, !config.supabaseAnonKey.isEmpty else {
            return nil
        }
        let c = SupabaseClient(
            supabaseURL: url,
            supabaseKey: config.supabaseAnonKey,
            options: SupabaseClientOptions(
                auth: SupabaseClientOptions.AuthOptions(
                    storage: KeychainStorage()
                )
            )
        )
        _client = c
        return c
    }

    init(
        config: AppConfig,
        biometric: BiometricUnlockServicing = BiometricUnlockService(),
        isBiometricGateEnabled: @escaping () -> Bool = { AuthService.defaultBiometricGateGetter() },
        google: GoogleSignInServicing? = nil
    ) {
        self.config = config
        self.biometric = biometric
        self.isBiometricGateEnabled = isBiometricGateEnabled
        // GoogleSignInService is @MainActor; constructing it in the
        // default-arg expression triggers a Swift 6 isolation diag
        // because the caller may not be MainActor-isolated. Build it
        // here in the @MainActor init body instead.
        self.google = google ?? GoogleSignInService()

        var continuation: AsyncStream<AuthState>.Continuation!
        self.stateChange = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    func currentAccessToken() -> String? {
        client?.auth.currentSession?.accessToken
    }

    nonisolated static func defaultBiometricGateGetter() -> Bool {
        UserDefaults.standard.object(forKey: "lumo.biometric.enabled") as? Bool ?? true
    }

    nonisolated static func setBiometricGateEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "lumo.biometric.enabled")
    }

    // MARK: - AuthServicing

    func restoreSession() async {
        guard let client else {
            state = .signedOut
            return
        }
        do {
            let session = try await client.auth.session
            let user = Self.lumoUser(from: session.user)
            if isBiometricGateEnabled() && biometric.isBiometryAvailable() {
                state = .needsBiometric(user)
            } else {
                state = .signedIn(user)
            }
        } catch {
            // No session in Keychain or expired and refresh failed.
            state = .signedOut
        }
    }

    func signInWithApple(_ credential: AppleCredential) async throws {
        guard let client else {
            throw AuthServiceError.notConfigured
        }
        state = .signingIn
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: credential.idTokenString,
                    nonce: credential.rawNonce
                )
            )
            let user = Self.lumoUser(from: session.user, fallbackEmail: credential.email, fallbackName: credential.fullName)
            // After fresh sign-in the user has just authenticated with
            // Apple; skip the biometric gate for this session.
            state = .signedIn(user)
        } catch {
            state = .signedOut
            throw error
        }
    }

    func signInWithGoogle() async throws {
        guard let client else {
            throw AuthServiceError.notConfigured
        }
        state = .signingIn
        do {
            // Native Google Sign-In via GIDSignIn returns an id_token
            // directly; we exchange that with Supabase via
            // `signInWithIdToken` — the same pattern Apple Sign-In
            // uses. Bypasses the OAuth web-redirect flow entirely.
            //
            // We previously tried Supabase's web-flow OAuth (both
            // manual choreography AND the SDK's signInWithOAuth(
            // configure:) helper) — both surfaced a 400 from
            // Supabase /token reading "both auth code and code
            // verifier should be non-empty", because the redirect
            // from Supabase /callback was landing on www.orchet.ai
            // (the project's SITE_URL) instead of the custom-scheme
            // lumo://auth/callback we asked for, and the web shell
            // there raced an exchange without an iOS verifier.
            let idToken = try await GoogleNativeSignIn.idToken()
            let session = try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .google,
                    idToken: idToken
                )
            )
            let user = Self.lumoUser(from: session.user)
            // Fresh sign-in — skip the biometric gate for this session,
            // matching the Apple path.
            state = .signedIn(user)
        } catch {
            state = .signedOut
            throw error
        }
    }

    func unlockWithBiometric() async throws {
        guard case .needsBiometric(let user) = state else { return }
        let kind = biometric.biometryKind().label
        let unlocked = try await biometric.authenticate(reason: "Unlock \(Brand.name) with \(kind)")
        if unlocked { state = .signedIn(user) }
    }

    func signOut() async {
        if let client {
            try? await client.auth.signOut()
        }
        state = .signedOut
    }

    func devSignIn() async {
        #if DEBUG
        // Sign in to a real Supabase test account so the gateway gets
        // a valid JWT for downstream chat / marketplace / voice calls.
        // The earlier synthetic-LumoUser path produced no
        // accessToken, so every API call hit a 401 at the gateway.
        guard let client else {
            let stub = LumoUser(id: "dev-user", email: "dev@orchet.local", displayName: "Dev User")
            state = .signedIn(stub)
            return
        }
        state = .signingIn
        do {
            let session = try await client.auth.signIn(
                email: "dev@orchet.ai",
                password: "OrchetDevPass!2026"
            )
            let user = Self.lumoUser(from: session.user)
            state = .signedIn(user)
        } catch {
            // Fall back to the synthetic user so the simulator at
            // least lands on the chat surface, even though calls
            // will still 401. Surface the failure in logs so the
            // dev knows to check Supabase availability.
            print("[auth] devSignIn fell back to stub: \(error.localizedDescription)")
            let stub = LumoUser(id: "dev-user", email: "dev@orchet.local", displayName: "Dev User")
            state = .signedIn(stub)
        }
        #endif
    }

    // MARK: - Helpers

    private static func lumoUser(
        from supabaseUser: User,
        fallbackEmail: String? = nil,
        fallbackName: PersonNameComponents? = nil
    ) -> LumoUser {
        let email = supabaseUser.email ?? fallbackEmail
        let metadataName = supabaseUser.userMetadata["name"]?.stringValue
            ?? supabaseUser.userMetadata["full_name"]?.stringValue
        let appleName = fallbackName.flatMap { Self.formatPersonName($0) }
        return LumoUser(
            id: supabaseUser.id.uuidString,
            email: email,
            displayName: metadataName ?? appleName
        )
    }

    private static func formatPersonName(_ components: PersonNameComponents) -> String? {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let s = formatter.string(from: components)
        return s.isEmpty ? nil : s
    }
}

enum AuthServiceError: Error, LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sign-in is not configured for this build. Run `scripts/ios-write-xcconfig.sh` with LUMO_SUPABASE_URL + LUMO_SUPABASE_ANON_KEY in env."
        }
    }
}

/// AnyJSON convenience: pull a string out of Supabase user metadata
/// without throwing on missing keys.
private extension AnyJSON {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
