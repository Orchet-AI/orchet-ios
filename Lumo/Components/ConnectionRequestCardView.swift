import SwiftUI

/// PARITY-1D — inline OAuth-connect surface for marketplace agents
/// the user hasn't authorized yet. Mirrors the web
/// `ConnectionRequestCard` (orchet-web 1:1).
///
/// Renders when the orchestrator emits a `connection_required` SSE
/// frame. The frame carries a pre-minted OAuth 2.1 authorize URL —
/// we open it via `ASWebAuthenticationSession`, wait for the
/// callback, then fire `onConnected` so `ChatViewModel.
/// handleConnectionCompleted` can auto-send a follow-up turn that
/// resumes the original request.
///
/// Four visual states matching web:
///   - idle       — "Connect {Provider}" button
///   - connecting — sheet up, button disabled, "Waiting for {Provider}…"
///   - connected  — checkmark, "Connected. Resuming your request…"
///   - error      — recoverable; user can retry
struct ConnectionRequestCardView: View {
    let value: ConnectionRequiredFrameValue
    let onConnected: (String) -> Void

    @State private var state: CardState = .idle
    @State private var errorMessage: String? = nil
    @State private var oauthSession: OAuthWebAuthSession? = nil

    enum CardState: Equatable {
        case idle
        case connecting
        case connected
        case error
    }

    /// Callback URL scheme registered in `Info.plist` for OAuth
    /// callbacks. Matches the existing Supabase auth flow scheme.
    private static let callbackScheme = "orchet"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(LumoColors.separator)
            body_
            Divider().background(LumoColors.separator)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                .fill(LumoColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                .stroke(LumoColors.separator, lineWidth: 1)
        )
        .accessibilityIdentifier("chat.connection-required.\(value.agent_id)")
    }

    private var header: some View {
        HStack(spacing: LumoSpacing.sm) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LumoColors.labelSecondary)
            Text("Connect \(value.display_name)")
                .font(LumoFonts.bodyEmphasized)
                .foregroundStyle(LumoColors.label)
            Spacer()
        }
        .padding(.horizontal, LumoSpacing.md)
        .padding(.vertical, LumoSpacing.sm + 2)
    }

    @ViewBuilder
    private var body_: some View {
        Text(
            "Sign in to \(value.display_name) to continue with your request. " +
            "Your credentials go directly to \(value.display_name) — Orchet " +
            "only stores the access token."
        )
        .font(LumoFonts.callout)
        .foregroundStyle(LumoColors.labelSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, LumoSpacing.md)
        .padding(.vertical, LumoSpacing.sm + 2)
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: LumoSpacing.xs) {
            if state == .connected {
                connectedRow
            } else {
                connectButton
                if let message = errorMessage {
                    Text(message)
                        .font(LumoFonts.caption)
                        .foregroundStyle(LumoColors.warning)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, LumoSpacing.md)
        .padding(.vertical, LumoSpacing.sm + 2)
    }

    private var connectedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LumoColors.success)
            Text("Connected. Resuming your request…")
                .font(LumoFonts.callout)
                .foregroundStyle(LumoColors.label)
        }
    }

    private var connectButton: some View {
        Button {
            Task { await beginConnect() }
        } label: {
            Text(connectButtonLabel)
                .font(LumoFonts.bodyEmphasized)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LumoSpacing.sm + 2)
                .background(
                    RoundedRectangle(cornerRadius: LumoRadius.md, style: .continuous)
                        .fill(state == .connecting ? LumoColors.labelTertiary : LumoColors.cyan)
                )
        }
        .disabled(state == .connecting)
        .accessibilityIdentifier("chat.connection-required.\(value.agent_id).connect")
    }

    private var connectButtonLabel: String {
        switch state {
        case .connecting: return "Waiting for \(value.display_name)…"
        case .error: return "Try again — Connect \(value.display_name)"
        default: return "Connect \(value.display_name)"
        }
    }

    @MainActor
    private func beginConnect() async {
        guard let url = URL(string: value.authorize_url) else {
            state = .error
            errorMessage = "Invalid sign-in link. Please ask again."
            return
        }
        errorMessage = nil
        state = .connecting

        let session = OAuthWebAuthSession()
        oauthSession = session
        let result = await session.start(
            authorizeURL: url,
            callbackScheme: Self.callbackScheme
        )

        switch result {
        case .success:
            state = .connected
            onConnected(value.agent_id)
        case .canceled:
            state = .error
            errorMessage = "Sign-in didn't complete. Try again when you're ready."
        case .error(let detail):
            state = .error
            errorMessage = "Sign-in failed: \(detail)"
        }
        oauthSession = nil
    }
}
