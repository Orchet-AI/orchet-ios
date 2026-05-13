# Codex brief — ORCHET-IOS-PARITY-1: Daily streaming voice + live transcripts + real marketplace install

**Brief ID:** ORCHET-IOS-PARITY-1-CODEX
**Parent ADR:** [VOICE-ARCHITECTURE-1](../../orchet-voice/docs/architecture/VOICE-ARCHITECTURE-1.md)
**Supersedes:** [VOICE-PHASE-6-CODEX-BRIEF](../../orchet-voice/docs/briefs/VOICE-PHASE-6-CODEX-BRIEF.md) — Phase 6 was drafted 2026-05-11 but never executed. This brief folds Phase 6 scope into a single PR alongside the new web parity work shipped 2026-05-14.
**Predecessors:** Web PRs merged on 2026-05-14:
  - `Orchet-AI/orchet-voice` — `feat/live-transcript-app-messages`
  - `Orchet-AI/orchet-web` — `feat/live-voice-transcript-in-chat`
  - `Orchet-AI/orchet-voice` — `fix/voice-agent-query-default-route`
  And the voice tool catalog now includes `marketplace_find_agents` + `marketplace_install_agent` direct tools.
**Status:** Drafted 2026-05-14
**Owner:** Codex
**Reviewer:** Kalas + Claude
**Estimated effort:** 8–11 days
**Repo:** [Orchet-AI/orchet-ios](https://github.com/Orchet-AI/orchet-ios)

This brief brings iOS to functional parity with the web voice + marketplace stack. Web users now see live user/assistant transcript bubbles inline in the chat thread during voice calls, and Orchet's voice agent can discover + install marketplace agents through `marketplace_find_agents` / `marketplace_install_agent`. iOS today is still on the batch HTTP push-to-talk path (`apps/web/api/stt` style), has no Daily SDK at all, and the Marketplace install button is a local-state placeholder. After this PR, an iOS user can hold the mic, hear Orchet stream a response, see both sides of the conversation render inline as it happens, and tap "Install" on a marketplace agent and have it actually install.

---

## Predecessor gates

Do NOT start this brief until ALL of the following are true:

1. `feat/live-transcript-app-messages` merged to `Orchet-AI/orchet-voice@main`. The new processor sits in `voice/transport.py` between `MigrationFrameSenderProcessor` and `transport_output`.
2. `feat/live-voice-transcript-in-chat` merged to `Orchet-AI/orchet-web@main`. The reference implementation for the data-channel handlers and the inline-bubble parent wiring.
3. `fix/voice-agent-query-default-route` merged to `Orchet-AI/orchet-voice@main`. The updated voice prompt + tool catalog (you'll use the same agent_id strings on iOS).
4. `orchet-voice.fly.dev` is the production voice service host with all three above deployed.
5. Honeycomb 6h breakdown over `name = "voice.orchestrator.voice_turn"` shows `agent_query`, `marketplace_find_agents`, and `marketplace_install_agent` actively being called from web sessions. If `agent_query` is still under 5% of total voice turns, STOP — the voice prompt is not landing and iOS will inherit the same problem.

If any of the five are false: STOP and report. The whole point of staging web first is to derisk iOS.

---

## Goal

Add a Daily WebRTC streaming voice path to `orchet-ios`, gated behind a runtime feature flag (default-off in production, default-on in TestFlight). Wire the three new live-transcript Daily app-messages into the iOS chat thread the same way web does. Replace the `IOS-MARKETPLACE-INSTALL-1` placeholder with a real install round-trip, and surface voice-driven marketplace_find_agents / marketplace_install_agent calls inside the same install flow.

Keep the deploy boring: ship the code, leave the streaming flag default-off in production, flip via `Lumo.local.xcconfig` per build. Manual TestFlight soak before production.

---

## Hard scope boundaries

**You MUST NOT:**

- Delete `DeepgramTokenService`, `TextToSpeechService`, `VoiceComposerViewModel`, or `SpeechModeGating`. They stay as the batch-path implementation behind the flag. iOS users on builds without the flag set keep the legacy push-to-talk surface.
- Remove the gateway `/stt` or `/tts` routes (separate cleanup PR after this brief stabilizes).
- Change the voice service contract — `orchet-voice`'s `/voice/start`, `/voice/turn`, `/voice/confirm-action`, and the Daily app-message payload shapes are STABLE. Match them exactly; don't re-design them.
- Add Sarvam-specific iOS code. Sarvam wiring is server-side; iOS just sends locale and lets the voice service route.
- Bump `IPHONEOS_DEPLOYMENT_TARGET` above 17.0. Daily Swift SDK supports iOS 13+; we're well past.
- Add CocoaPods. This project is SPM-only — keep it that way.
- Touch `OrchetWatch/` in this PR. Watch app parity is a separate brief.
- Replace `Lumo` as the SwiftUI app target name. The directory is `Lumo/` and the schema is `Lumo` — leave it; we rebrand the Xcode target in a coordinated cutover later. Bundle identifier (`com.lumo.rentals.*`) also stays in this PR.
- Auto-dispatch user transcripts through chat `/turn`. In streaming mode the voice service is running its OWN LLM (Groq Llama via the voice tool catalog) and the audio reply is already coming back over the Daily channel. If you dispatch the transcript through chat /turn you'll trigger Claude Sonnet in parallel and the rendered chat will diverge from what the user heard — exactly the bug we just fixed on web.

**You MUST:**

- Add `LumoVoiceBackend` enum (`.streaming`, `.batch`) with default `.batch`, read at app launch from `Info.plist` key `OrchetVoiceMode`.
- Populate `Info.plist` keys `OrchetVoiceMode` and `OrchetVoiceBase`. Backing xcconfig vars: `ORCHET_VOICE_MODE` (default `batch`), `ORCHET_VOICE_BASE` (default `https://orchet-voice.fly.dev`).
- Add the **Daily Swift SDK** as an SPM dependency in `project.yml`.
- Add `Lumo/Services/StreamingVoiceService.swift` mirroring the web `StreamingVoiceMode` shape — Daily call object, audio in/out, native barge-in, app-message subscription.
- Build a native `VoiceConfirmationView` that mounts when a `voice_show_confirmation` Daily app message arrives. Mirror the web modal's UX: title, summary, label/value details, Confirm + Cancel, auto-expire on `expires_at`.
- After Confirm/Cancel, POST to `${OrchetAPIBase}/voice/confirm-action` with the Supabase JWT, then `sendAppMessage` a `confirmation_resolved` event back over Daily. Payload shape: `{ type: "confirmation_resolved", confirmation_id, accepted: bool, result: { result, voice_continuation_hint } }`.
- Subscribe to the three new transcript app-messages (`voice_user_transcript`, `voice_assistant_transcript_delta`, `voice_assistant_transcript_final`). Route them into the chat-thread message list — see Part E.
- Subscribe to the existing `voice_session_migrate` app-message and reconnect cleanly to the target region (same shape the web client already handles in `useVoiceSessionMigration`).
- Implement native VAD via `AVAudioEngine`'s `installTap` — RMS-based threshold detector. **Do NOT use Silero on iOS** (too much WASM/ONNX baggage). Send `barge_in` app messages on speech start / end same as the web client.
- Background audio session: configure `.playAndRecord` with `.mixWithOthers` (Spotify integration coexists). Add `audio` to `UIBackgroundModes` so calls survive screen lock.
- Replace the `IOS-MARKETPLACE-INSTALL-1` placeholder in `Lumo/Views/MarketplaceView.swift` (`MarketplaceAgentDetailView.handleInstallTap`) with a real `POST ${OrchetAPIBase}/marketplace/install` call carrying the Supabase JWT. Update `MarketplaceScreenViewModel.installError` / `installingAgentID` on the response. Reflect the new connection status by polling `GET ${OrchetAPIBase}/connections` after a successful install (or by subscribing to the existing connection-status push if it exists — check `apps/web` for the equivalent).
- Bridge voice-driven marketplace installs into the same install path. When the voice LLM calls `marketplace_install_agent`, the voice service emits a `voice_show_confirmation` for high-risk installs and an `executed` outcome for low-risk ones. iOS already handles the show_confirmation path via Part B; for low-risk auto-installs, surface a toast and refresh the marketplace list.
- Match the iOS architecture pattern: `Lumo/Services/`, `Lumo/ViewModels/`, `Lumo/Components/`, `Lumo/Views/`. Tests in `LumoTests/`.
- Branch on `LumoVoiceBackend.current` at the voice-button entry-point in `Lumo/Components/ChatComposerTrailingButton.swift` (or wherever today's voice button mounts) — render the streaming UI when `.streaming`, existing push-to-talk when `.batch`.

---

## Deliverable: single PR to `orchet-ios`

**Title:** `ORCHET-IOS-PARITY-1: Daily streaming voice + live transcripts + real marketplace install`

### Part A — SPM dep + Info.plist + xcconfig

1. Add to `project.yml` under `packages:`:

   ```yaml
   Daily:
     url: https://github.com/daily-co/daily-client-ios
     from: "0.27.0"
   ```

   Verify the exact tag by inspecting the daily-client-ios releases page — pick the latest 0.x stable. If 1.0 has shipped, prefer that. Add to the `Lumo` target's `dependencies:` list.

2. Regenerate `Lumo.xcodeproj` with XcodeGen and commit the resulting changes.

3. `Info.plist` additions:

   ```xml
   <key>OrchetVoiceMode</key>
   <string>$(ORCHET_VOICE_MODE)</string>
   <key>OrchetVoiceBase</key>
   <string>$(ORCHET_VOICE_BASE)</string>
   ```

4. Extend `Lumo.xcconfig` with defaults `ORCHET_VOICE_MODE = batch` and `ORCHET_VOICE_BASE = https://orchet-voice.fly.dev`. Extend `scripts/ios-write-xcconfig.sh`'s allow-list to accept both keys.

5. `UIBackgroundModes` already includes `remote-notification`, `fetch`, `processing`. Add `audio`.

### Part B — feature flag + service entry point

6. New file `Lumo/Services/VoiceBackendConfig.swift`:

   ```swift
   enum LumoVoiceBackend: String { case streaming, batch }

   struct VoiceBackendConfig {
       static let current: LumoVoiceBackend = {
           let raw = Bundle.main.object(forInfoDictionaryKey: "OrchetVoiceMode") as? String
           return LumoVoiceBackend(rawValue: raw ?? "") ?? .batch
       }()

       static var voiceServiceBaseURL: URL {
           let raw = Bundle.main.object(forInfoDictionaryKey: "OrchetVoiceBase") as? String
               ?? "https://orchet-voice.fly.dev"
           return URL(string: raw)!
       }
   }
   ```

7. New file `Lumo/Services/StreamingVoiceService.swift`. Owns:
   - `CallClient` instance from Daily SDK.
   - `start(sessionId:userJWT:)` → POST `${voiceServiceBaseURL}/voice/start` with bearer JWT, get back `{ room_url, client_token, session_id }`, join the room.
   - App-message subscription via Daily SDK's app-message delegate.
   - `sendAppMessage(_:)` helper.
   - `stop()` → graceful leave + cleanup.
   - Publishes via Combine: `@Published var state: StreamingVoiceState`, `@Published var lastError: String?`, plus subjects per app-message kind (see Part E).

8. New file `Lumo/ViewModels/StreamingVoiceViewModel.swift`. Mirrors the existing `VoiceComposerViewModel` shape but for the streaming surface — owns the call lifecycle, surfaces state for the SwiftUI view, and exposes a `requestBargeIn()` method that emits the same `barge_in` app message the web client sends.

9. New file `Lumo/Views/StreamingVoiceView.swift` — the SwiftUI surface. Layout: mic button (tap = toggle mute, long-press = barge-in if you want hands-free; do NOT auto-listen — per [mic-vs-send-button doctrine](docs/doctrines/mic-vs-send-button.md) iOS is push-to-talk by design).

10. Mount-point: branch in `Lumo/Components/ChatComposerTrailingButton.swift`:

    ```swift
    if VoiceBackendConfig.current == .streaming {
        StreamingVoiceButton()  // new
    } else {
        VoiceComposerButton()    // existing
    }
    ```

### Part C — native VAD + barge-in

11. New file `Lumo/Services/NativeVADService.swift`:
    - `AVAudioEngine` with `installTap(onBus:0)` reading 16 kHz mono Float32 buffers.
    - RMS computed per buffer; threshold = -45 dBFS (tune in soak; surface as a constant for easy adjustment).
    - Debounce: 2 consecutive over-threshold buffers → `speechStarted`. 14 consecutive under-threshold → `speechEnded`. Match the web Silero values from `VoiceMode.tsx` (`minSpeechFrames: 2`, `redemptionFrames: 14`).
    - Emit `barge_in` app-messages with `{ type: "barge_in", phase: "speech_started" | "speech_ended", client_sent_at }` — same shape the web client emits.

12. Wire NativeVADService into StreamingVoiceService.start() so it begins capturing on join and stops on leave. The VAD runs in PARALLEL to the Daily SDK's own audio capture — the SDK sends audio upstream; native VAD only informs the local barge-in decision.

### Part D — native confirmation modal

13. New file `Lumo/Components/VoiceConfirmationView.swift`. Receives a `VoiceShowConfirmationMessage` (Codable matching the web TS type), renders title / summary / detail list / Confirm + Cancel. Auto-cancel via `Task.sleep` until `expires_at`.

14. On Confirm or Cancel, POST `${OrchetAPIBase}/voice/confirm-action` with `{ session_id, confirmation_id, accepted }` and the Supabase JWT. The response body is `{ result: "executed" | "cancelled", tool_call_id?, summary?, voice_continuation_hint }`. Pass the result back into Daily as `{ type: "confirmation_resolved", confirmation_id, accepted, result: <body> }`. The voice service uses this to continue speaking.

15. Mount the modal as a SwiftUI `.sheet(item: $confirmation)` over the chat surface. The chat parent listens for the confirmation subject on `StreamingVoiceService` and sets `confirmation` when a `voice_show_confirmation` arrives.

### Part E — live transcripts inline in the chat thread

This is the new parity work — mirrors web's `feat/live-voice-transcript-in-chat`.

16. Add Codable types to `Lumo/Services/StreamingVoiceService.swift`:

    ```swift
    struct VoiceUserTranscriptMessage: Codable, Identifiable {
        let type: String  // "voice_user_transcript"
        let voice_session_id: String
        let turn_id: String?
        let text: String
        var id: String { "\(voice_session_id):\(turn_id ?? UUID().uuidString)" }
    }

    struct VoiceAssistantTranscriptDeltaMessage: Codable {
        let type: String  // "voice_assistant_transcript_delta"
        let voice_session_id: String
        let turn_id: String?
        let text: String  // delta only — NOT cumulative
    }

    struct VoiceAssistantTranscriptFinalMessage: Codable {
        let type: String  // "voice_assistant_transcript_final"
        let voice_session_id: String
        let turn_id: String?
        let text: String  // full cumulative response
    }
    ```

17. Add three `PassthroughSubject`s on `StreamingVoiceService` and publish them from the app-message delegate when the `type` field matches. Use `JSONDecoder` against the raw payload dict.

18. In `Lumo/ViewModels/ChatViewModel.swift`, subscribe to the three subjects when the streaming voice service is active. On each message:
    - `voice_user_transcript` → append a new `ChatMessage(role: .user, content: msg.text)`. Do NOT call the existing `sendMessage(_:)` method that posts to chat `/turn` — see scope boundary above. Just append the bubble.
    - `voice_assistant_transcript_delta` → if `inflightAssistantMessageID == nil`, create a new `ChatMessage(role: .assistant, content: msg.text)` and store its id; else, find that message and append `msg.text` to its content. The id tracking lives on the view model.
    - `voice_assistant_transcript_final` → find the in-flight assistant message, replace its content with `msg.text` (reconciliation in case a delta dropped), clear `inflightAssistantMessageID`.

19. Render: `Lumo/Views/ChatView.swift` already renders `ChatMessage`s — no view-side change needed if the view model just mutates the message list. Verify the existing transcript banner (`ChatView.swift:268` per the parity audit) still renders for the legacy batch path; the new path bypasses it.

### Part F — Marketplace: real install + voice-driven install

20. In `Lumo/Views/MarketplaceView.swift`, locate `MarketplaceAgentDetailView.handleInstallTap` (around line 468). Replace the placeholder with:

    ```swift
    private func handleInstallTap() {
        Task {
            await viewModel.install(agentID: agent.agent_id, jwt: currentSupabaseJWT())
        }
    }
    ```

21. In `MarketplaceScreenViewModel`, add:

    ```swift
    func install(agentID: String, jwt: String) async {
        installingAgentID = agentID
        installError = nil
        defer { installingAgentID = nil }
        do {
            let result = try await marketplaceService.install(agentID: agentID, jwt: jwt)
            // refresh installed flags so the detail view re-renders "Connected"
            await reload()
        } catch {
            installError = error.localizedDescription
        }
    }
    ```

22. New file `Lumo/Services/MarketplaceService.swift` — `install(agentID:jwt:)` POSTs to `${OrchetAPIBase}/marketplace/install` with `{ agent_id }`, bearer JWT. Response shape matches the web client: `{ ok: true, connection_id?, oauth_authorize_url? }`. If `oauth_authorize_url` is present, the agent needs OAuth — open it via `ASWebAuthenticationSession` (full OAuth wiring is a follow-up brief, but the entry point belongs here).

23. Voice-driven path. When the voice LLM calls `marketplace_install_agent`, two outcomes are possible from the voice service:
    - **executed** (low-risk install) — the voice service has already initiated install via the backend. iOS shows a toast "Installed <agent_name>" and refreshes the marketplace list. Driven by a new app-message kind `voice_marketplace_installed` you'll need to add on BOTH sides (server emit + iOS handler).
    - **requires_visual_confirmation** (high-risk or first OAuth install) — the existing `voice_show_confirmation` path already handles this; the modal renders, the user taps Confirm, the iOS POST to `/voice/confirm-action` triggers the real install server-side.

    For this PR, implement only the `voice_show_confirmation` path. Document the toast/refresh path as a stretch in the PR body if you have time.

### Part G — tests

24. `LumoTests/StreamingVoiceServiceTests.swift`. Mock `CallClient`; assert:
    - App-message dispatch routes the three transcript kinds to the right subjects.
    - `voice_show_confirmation` mounts a `VoiceShowConfirmationMessage`.
    - `barge_in` is emitted on speech_started / speech_ended.
    - `confirmation_resolved` is sent after the POST resolves.

25. `LumoTests/ChatViewModelStreamingTranscriptTests.swift`:
    - Three delta messages followed by a final → exactly one assistant ChatMessage with the final's text.
    - A user transcript → user ChatMessage appended, NO chat /turn HTTP request fired.
    - Final arrives without any preceding deltas → a single assistant message with the final's text.

26. `LumoTests/MarketplaceInstallTests.swift`:
    - install() success path → installError nil, list refreshed.
    - install() 4xx → installError populated.
    - install() returning `oauth_authorize_url` → ASWebAuthenticationSession invoked (mock the session class).

27. UI smoke (optional): one XCUITest launching with `ORCHET_VOICE_MODE=streaming`, tapping the streaming voice button, and asserting connecting state appears. Without a real mic in CI, just verify the UI state machine reaches `connecting`.

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

All three must pass on the existing GitHub Actions matrix (`.github/workflows/ci.yml`).

Manual smoke (do BEFORE marking ready-for-review; capture screenshots in the PR body):

1. Set `ORCHET_VOICE_MODE=streaming` in `Lumo.local.xcconfig`. Build to simulator + real device.
2. Sign in. Open voice mode. Verify the streaming UI appears.
3. Say "what time is it in Tokyo?" — expect spoken response within ~1.5s mouth-to-ear.
4. Watch the chat thread DURING speech — user bubble lands when you stop, assistant bubble streams in token-by-token, final text reconciles cleanly.
5. Say "book me a flight to Tokyo tomorrow" — voice continues + native confirmation modal mounts. Confirm. Voice continues with "Done. Confirmation code …".
6. Talk OVER the TTS — assistant stops within ~300 ms (native barge-in).
7. Open marketplace, tap Install on a free agent (e.g. weather). Expect spinner, then status flip to "Connected" without crash.
8. Open marketplace, tap Install on an OAuth agent (Google). Expect ASWebAuthenticationSession to launch with `accounts.google.com`.
9. In voice mode, say "install the weather agent". Expect either auto-install or the confirmation modal — either is acceptable for this PR; document which path fires.
10. Switch `ORCHET_VOICE_MODE=batch`, rebuild. Verify legacy push-to-talk surface still works — no regression.
11. Background the app mid-call. Verify audio continues (`UIBackgroundModes` includes `audio`).
12. Lock the device mid-call. Verify call survives.

Capture five Honeycomb permalinks for the PR body: `client.kind=ios` filtered on `voice.total.mouth_to_ear`, `voice.tts.barge_in_ms`, `voice.turn.outbound`, `voice.tool_call.name = marketplace_install_agent`, and the new `voice.transcript.*` spans (if you add instrumentation; optional).

---

## Stop conditions (report, don't work around)

- **Daily Swift SDK API drift** — the `CallClient` shape, `sendAppMessage` signature, or callback model differs from this brief. Adapt and document the version; STOP if the SDK doesn't expose the primitives we need.
- **AVAudioSession conflicts with Spotify** — if `.mixWithOthers` can't coexist with the Daily SDK's session expectations, STOP and report. Fallback: suspend Spotify on voice-mode entry.
- **Native VAD RMS threshold too noisy** — try AVAudioSession's `inputGain`, raise the debounce window, or fall back to server-side endpointing (Deepgram's `endpointing=300ms` is already on in orchet-voice). Document the choice in code comments.
- **Background-audio entitlement requires App Store review** — `UIBackgroundModes` already has the key; if Xcode complains about a missing entitlement on real-device build, fix the entitlement file and document.
- **`xcodebuild test` fails on existing tests after adding the Daily SPM dep** — the dep import may pull in an Obj-C bridging header that doesn't compile under the project's settings. STOP, report; we may need a bridging header or `OTHER_SWIFT_FLAGS`.
- **`Lumo.xcconfig` allow-list rejects new env vars** — read `scripts/ios-write-xcconfig.sh` and extend its allow-list to include `ORCHET_VOICE_MODE` and `ORCHET_VOICE_BASE`.
- **Daily SDK bumps iOS deployment target above 17.0** — STOP, report. We do not bump deployment target without separate review.
- **Marketplace install API contract mismatch** — if `POST /marketplace/install` doesn't accept `{ agent_id }` or returns a shape that doesn't match what `apps/web` consumes, STOP and surface the mismatch. Don't ship a half-working install button.
- **Voice user transcript triggers double dispatch** — if despite the explicit guard you find chat /turn being invoked from a streaming user transcript, STOP. The guard is load-bearing — see the web parity PR for the precedent.

---

## What "done" looks like

1. PR ready-for-review on `Orchet-AI/orchet-ios@main`.
2. CI green (xcodegen + xcodebuild build + xcodebuild test).
3. PR body includes:
   - Screenshots of: streaming voice UI, in-flight transcript bubbles, native confirmation modal, marketplace install spinner → connected state.
   - Five Honeycomb permalinks (mouth-to-ear, barge-in, /voice/turn, marketplace_install_agent calls, voice.transcript.* if instrumented), all filtered on `client.kind=ios`.
   - One real-device smoke transcript: voice booking flight → confirm modal → voice continuation → user bubble + assistant bubble visible inline.
   - Side-by-side streaming vs batch behavior proving the flag swap is clean.
   - Note on the voice-driven install path you chose (auto-install vs always-confirm).
4. Default flag is `batch` in production xcconfig; `streaming` in TestFlight xcconfig.
5. After 7 days of TestFlight `ORCHET_VOICE_MODE=streaming` with no P1 incident, ops flips production xcconfig and ships an App Store update.

After this PR closes, both web and iOS users hit `orchet-voice.fly.dev` directly, both see live transcripts in the chat thread, and both have a real marketplace install button. The gateway `/stt` and `/tts` routes can be retired in a small follow-up labelled `PHASE-6-CLEANUP`.

---

## References

- [VOICE-ARCHITECTURE-1 ADR](../../orchet-voice/docs/architecture/VOICE-ARCHITECTURE-1.md)
- [VOICE-PHASE-6-CODEX-BRIEF](../../orchet-voice/docs/briefs/VOICE-PHASE-6-CODEX-BRIEF.md) — predecessor brief this one supersedes
- [web ↔ iOS feature parity audit 2026-05-03](../../orchet-backend/docs/notes/web-ios-parity-audit-2026-05-03.md)
- [Daily Swift SDK](https://github.com/daily-co/daily-client-ios)
- [Daily app messages](https://docs.daily.co/reference/daily-js/instance-methods/send-app-message) — payload shape matches between iOS and web
- Reference TypeScript implementations (translate directly to Swift):
  - `orchet-web/lib/voice-data-channel.ts` — the dispatch hook + Codable shapes
  - `orchet-web/components/VoiceMode.tsx` `StreamingVoiceMode` — UI state machine
  - `orchet-web/app/page.tsx` — the inline-bubble parent wiring with `voiceAssistantInflightRef`
  - `orchet-voice/voice/transport.py` `TranscriptAppMessageProcessor` — server-side emit contract
