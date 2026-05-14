# Codex brief — ORCHET-IOS-PARITY-1D: connection_required frame + ConnectionRequestCard

**Brief ID:** ORCHET-IOS-PARITY-1D-CODEX
**Parent brief:** [ORCHET-IOS-PARITY-1](./ORCHET-IOS-PARITY-1-CODEX-BRIEF.md)
**Sibling briefs:** PARITY-1A (search-cards, merged), PARITY-1B (reader drawer, merged), PARITY-1C (composed-ui, merged).
**Predecessors:** Web + backend PRs merged 2026-05-15:
  - `Orchet-AI/orchet-backend` — `feat/inline-connect-card` (OAuthStartPort, connection_required SSE frame, system-prompt rewrite, migration 075).
  - `Orchet-AI/orchet-web` — `feat/inline-connect-card` (`ConnectionRequestCard` + OAuth popup + auto-retry + popup-close path on `/connections`).
**Status:** Drafted 2026-05-15
**Owner:** Codex
**Reviewer:** Kalas + Claude
**Estimated effort:** 3-4 days
**Repo:** [Orchet-AI/orchet-ios](https://github.com/Orchet-AI/orchet-ios)

Add the iOS sibling of the inline-connect surface so iOS users get the same one-tap OAuth flow web users now have. Instead of telling the user "head to the Marketplace" when a tool needs Google/Lumo Rentals/Instacart/etc., the chat surface renders a `ConnectionRequestCardView` with a "Connect {Provider}" button. Tapping it opens `ASWebAuthenticationSession` against the authorize URL the orchestrator already minted; on completion the chat surface auto-sends a follow-up turn and the orchestrator retries the original tool with the new live connection.

This is pure rendering + frame-decode + ASWebAuthenticationSession orchestration. No new networking, no new backend changes.

---

## Predecessor gates

Do NOT start until ALL of the following are true:

1. `feat/inline-connect-card` merged to `Orchet-AI/orchet-backend@main` and deployed to Render.
2. `feat/inline-connect-card` merged to `Orchet-AI/orchet-web@main` and deployed to Vercel. Verify by asking the web chat "check my gmail" with a Google connection disconnected — the inline card should render with a working "Connect Google" button.
3. Postgres migration `075_events_frame_type_connection_required.sql` applied to prod Supabase (applied during backend PR build).
4. Honeycomb shows non-zero `connection_required` frame emission rate over a 1h window.

If any are false: STOP. iOS rendering against an envelope that's not in production will desync.

---

## Goal

Decode the `connection_required` SSE frame, model it as a Swift type matching the backend envelope, render an inline card under the assistant prose, run the OAuth via `ASWebAuthenticationSession`, auto-send the follow-up turn on completion. Match the web flow's behavior 1:1 so the system-prompt rules (model expects brief acknowledgement + waits for user's next turn) work identically on both platforms.

---

## Hard scope boundaries

**You MUST NOT:**

- Add networking. The frame arrives in the existing chat SSE stream. The OAuth dance is a single browser session via Apple's ASWebAuthenticationSession SDK — no custom URL handlers, no in-app WKWebView with cookies.
- Use `SFSafariViewController` for OAuth. `ASWebAuthenticationSession` is the correct primitive: shares cookies with Safari, returns the final URL via completion handler, supports ephemeral mode for sign-in flows.
- Re-mint the authorize URL on iOS. The backend already minted it with PKCE + state + redirect_uri. iOS just hands it to ASWebAuthenticationSession.
- Hard-code Google. The card is generic — provider info comes from the frame's `display_name` field.
- Touch `OrchetWatch/`. Watch parity is a separate brief.
- Bump deployment target above iOS 17.0.

**You MUST:**

- Add the Codable model in `Lumo/Models/ConnectionRequired.swift`:

  ```swift
  struct ConnectionRequiredFrameValue: Codable, Equatable {
      let agent_id: String
      let display_name: String
      let authorize_url: String
      let blocked_tool: String
  }
  ```

  Snake_case property names match the wire format exactly. Mirror the web shape guard's discipline: validate `authorize_url` starts with `https://` before rendering the card.

- Add the new frame case to the SSE-decode enum (`grep -n 'case .composedUI' Lumo/`):

  ```swift
  case connectionRequired(ConnectionRequiredFrameValue)
  // …
  case "connection_required":
      let v = try container.decode(ConnectionRequiredFrameValue.self, forKey: .value)
      self = .connectionRequired(v)
  ```

- Add `connectionRequired: ConnectionRequiredFrameValue?` to `ChatMessage` next to the existing `searchCards` / `composedUI` fields.

- Build `Lumo/Components/ConnectionRequestCardView.swift`:
  - Header: link icon + "Connect {display_name}"
  - Body: "Sign in to {display_name} to continue with your request. Your credentials go directly to {display_name} — Orchet only stores the access token."
  - Button: "Connect {display_name}" — disabled while session in flight; label flips to "Waiting for {display_name}…" while connecting; "Connected. Resuming your request…" + checkmark on success.
  - Error state: shows below the button when ASWebAuthenticationSession returns `.canceledLogin` or any error (treat both as the same recoverable state — "Sign-in didn't complete. Try again when you're ready.").

- Build `Lumo/Services/OAuthWebAuthSession.swift` wrapping ASWebAuthenticationSession:

  ```swift
  enum OAuthResult { case success; case canceled; case error(Error) }

  @MainActor
  final class OAuthWebAuthSession: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
      func start(authorizeURL: URL, callbackScheme: String) async -> OAuthResult {
          // ASWebAuthenticationSession.init(url:callbackURLScheme:completionHandler:)
          // Set prefersEphemeralWebBrowserSession = false (keep the Google session
          // alive for refresh-token reuse).
          // Return .success when the callback URL is reached, .canceled on user dismiss.
      }
      func presentationAnchor(for: ASWebAuthenticationSession) -> ASPresentationAnchor { /* current key window */ }
  }
  ```

  - `callbackScheme` is the URL scheme registered in `Info.plist` for the OAuth callback (`lumo` per `lib/auth.ts:47` — same scheme the existing Supabase auth flow uses). Verify in the host project's Info.plist before assuming.
  - The auth session's success URL contains the post-callback redirect — for inline-connect, this lands on `https://api.orchet.ai/connections/callback` which redirects to `/connections?connected=1&popup=1&agent_id=...`. iOS won't see the popup query string because the ASWebAuthenticationSession completion fires on the FIRST URL matching the callback scheme. So we accept any successful completion as "the user finished the dance" and trust the backend's connection persistence as the source of truth.

- Wire the auto-retry in the chat view-model:

  ```swift
  func handleConnectionCompleted(agentId: String, displayName: String) {
      guard !retriedConnectionAgentIds.contains(agentId) else { return }
      retriedConnectionAgentIds.insert(agentId)
      sendText("I've connected \(displayName). Please continue with my previous request.")
  }
  ```

  Dedupe per agent_id matching the web behavior.

- Mount in `ChatView.swift` below the existing assistant prose mount (after `SearchResultCardStack` / `ComposedUIView`):

  ```swift
  if let cr = message.connectionRequired {
      ConnectionRequestCardView(
          value: cr,
          onConnected: { [weak vm] agentId in
              vm?.handleConnectionCompleted(agentId: agentId, displayName: cr.display_name)
          }
      )
      .padding(.leading, 18)
  }
  ```

- History replay decode: pull `connectionRequired` off the chat-message replay JSON and reattach to `ChatMessage`. Note: authorize_url is short-lived (10 min state TTL on the backend) so cards in replayed turns may surface stale buttons. That's acceptable — the user can re-ask and the live path mints a fresh URL.

---

## Deliverable: single PR to `orchet-ios`

**Title:** `ORCHET-IOS-PARITY-1D: connection_required frame + ConnectionRequestCardView + ASWebAuthenticationSession`

### Part A — Codable models

1. `Lumo/Models/ConnectionRequired.swift` — `ConnectionRequiredFrameValue`.
2. Update the chat-frame SSE decoder to include the `connection_required` case.
3. Update `ChatMessage` to include `connectionRequired: ConnectionRequiredFrameValue?`.

### Part B — OAuth session

4. `Lumo/Services/OAuthWebAuthSession.swift` — ASWebAuthenticationSession wrapper.
5. Verify `Info.plist` registers the `lumo://` URL scheme (it should already from the existing Supabase auth flow). If not, add it and document the change.

### Part C — Card view

6. `Lumo/Components/ConnectionRequestCardView.swift` — the inline card matching the web UX states (idle / connecting / connected / error).

### Part D — Integration

7. Chat view-model: `handleConnectionCompleted(agentId:displayName:)` + per-agent_id dedup set.
8. `ChatView.swift` mounts `ConnectionRequestCardView` below the assistant prose when present.
9. History replay decoder pulls `connectionRequired` from message JSON; reattach to `ChatMessage`.

### Part E — Tests

10. `LumoTests/ConnectionRequiredDecodeTests.swift` — decode fixture JSON (capture from the orchet-backend `connection_required` SSE output for a "check my gmail" prompt with Google disconnected) and assert the model materializes the expected fields.
11. `LumoTests/ConnectionRequestCardViewTests.swift` — state transitions on the four card states; assert `onConnected` fires exactly once even on duplicate completion events.
12. `LumoTests/ConnectionRequiredPersistenceTests.swift` — replay a captured chat-message JSON with `connectionRequired` present → `ChatMessage.connectionRequired` is non-nil and decodes the same way as the live SSE path.

---

## Verification

```bash
xcodegen generate
xcodebuild build -scheme Lumo \
                 -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
                 CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme Lumo \
                 -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest' \
                 CODE_SIGNING_ALLOWED=NO
```

All three must pass.

Manual smoke (do BEFORE marking ready-for-review; capture screenshots in the PR body):

1. Build to simulator + real device.
2. Sign in. Disconnect Google in `/connections` (web) so iOS sees the disconnected state.
3. In the iOS chat, ask "Check my Gmail for the latest message."
4. Verify: assistant streams a brief acknowledgement ("Opening the Google sign-in for you — tap Connect to continue.") and renders the `ConnectionRequestCardView` inline.
5. Tap Connect Google. ASWebAuthenticationSession opens. Sign in with a Google account that grants the requested scopes.
6. On success, the session closes and the card flips to "Connected. Resuming your request…" with a checkmark.
7. Within ~2s the chat sends "I've connected Google. Please continue with my previous request." and the orchestrator dispatches `gmail_search_messages` successfully. Verify the actual Gmail result lands as a new assistant turn.
8. Tap the same card a second time (button is now hidden behind the "Connected" state) — verify no duplicate retry fires.
9. Run again, but this time cancel the ASWebAuthenticationSession dialog. Verify the card shows the error state and the connect button is re-enabled for retry.
10. Switch to dark mode → card surface + button readable.
11. iPad split-screen narrow → card lays out cleanly.
12. Pull-to-refresh or restart the chat → the `connectionRequired` field survives reload (test the persistence path).

Capture three Honeycomb permalinks filtered on `client.kind=ios`:
- `connection_required` frame emission count for iOS clients.
- Auto-retry follow-up turns (count chat turns matching the `"I've connected …. Please continue"` prefix).
- Turn-to-completion latency (from frame emission to first successful tool result after the retry).

---

## Stop conditions (report, don't work around)

- **`lumo://` scheme not registered in Info.plist** — the existing Supabase auth flow uses this scheme so it should already exist. If it doesn't, document the addition in the PR body and verify with `xcrun simctl` that the scheme dispatches correctly.
- **ASWebAuthenticationSession completion fires with the orchet.ai redirect URL but no readable connection state** — that's expected. The success of ASWebAuthenticationSession means the user reached the callback; the backend already persisted the connection. Treat completion as the trigger for `onConnected` regardless of the URL fragments.
- **The chat ViewModel can't reach `sendText` from `handleConnectionCompleted`** — that's a wiring bug, not an architectural one. Hoist the sendText handle the same way the existing FoodMenuSelect / FlightOffersSelect confirmation cards reach back to the chat send flow.
- **`connectionRequired` field is being emitted by the SSE but `ChatMessage.connectionRequired` stays nil** — same bug pattern that bit PR #20 on web. Check the SSE handler ALSO populates the field on the message, not just the local accumulator.
- **The backend envelope grows new fields after this brief was authored** — if `orchet-backend/packages/domain-orchestrator/src/executor/connection-required.ts` has more fields than the four listed (`agent_id`, `display_name`, `authorize_url`, `blocked_tool`), add them as optional Swift properties. Don't break decode for backwards compatibility.

---

## What "done" looks like

1. PR open against `Orchet-AI/orchet-ios@main` titled `ORCHET-IOS-PARITY-1D: connection_required frame + ConnectionRequestCardView + ASWebAuthenticationSession`.
2. All listed Xcode test suites pass in CI.
3. Manual smoke screenshots attached: idle card, ASWebAuthenticationSession sheet, connected state, retried turn returning real Gmail data, dark mode, iPad split-screen.
4. PR body links: this brief, the merged backend PR, the merged web PR, the Honeycomb permalinks above.
5. Reviewers (Kalas + Claude) tagged.
6. No new dependencies introduced. No `OrchetWatch/` changes. No iOS deployment target bump.
