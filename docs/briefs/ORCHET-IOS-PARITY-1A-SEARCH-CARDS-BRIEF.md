# Codex brief — ORCHET-IOS-PARITY-1A: SearchResultCard SwiftUI views

**Brief ID:** ORCHET-IOS-PARITY-1A-CODEX
**Parent brief:** [ORCHET-IOS-PARITY-1](./ORCHET-IOS-PARITY-1-CODEX-BRIEF.md)
**Predecessors:** Web + backend PRs merged 2026-05-14:
  - `Orchet-AI/orchet-backend` — `feat/search-cards-frame` (emits the SSE frame)
  - `Orchet-AI/orchet-web` — `feat/search-result-cards` (consumes the frame)
**Status:** Drafted 2026-05-14
**Owner:** Codex
**Reviewer:** Kalas + Claude
**Estimated effort:** 2-3 days
**Repo:** [Orchet-AI/orchet-ios](https://github.com/Orchet-AI/orchet-ios)

Add SwiftUI rendering for the new `search_cards` SSE frame so iOS users see the same inline image-rich cards web users now see when Orchet's answer is grounded in web_search. Pairs 1:1 with the React `<SearchResultCards>` component shipped on web.

This brief is intentionally narrow — pure rendering work, no new networking or backend changes. The SSE plumbing on iOS already deserializes frames into a typed enum; this brief just adds one new case and the SwiftUI views that render it.

---

## Predecessor gates

Do NOT start until ALL of the following are true:

1. `feat/search-cards-frame` merged to `Orchet-AI/orchet-backend@main` and deployed to Render.
2. `feat/search-result-cards` merged to `Orchet-AI/orchet-web@main` and deployed to Vercel. Verify by asking the web chat "what's the latest news from google" — image-rich cards should render under the assistant prose.
3. Honeycomb shows non-zero `search_cards` frame emission rate over a 1h window.

If any are false: STOP. iOS rendering against an envelope that's not in production will desync.

---

## Goal

Decode the `search_cards` SSE frame, model it as a Swift type that matches the backend envelope, and render it in `ChatView` directly below the assistant prose bubble — featured-card variant when `lead_story_index` is set, equal-weight grid otherwise.

---

## Hard scope boundaries

**You MUST NOT:**

- Add networking. The cards arrive in the existing chat SSE stream; we're rendering a new frame type, not fetching anything new.
- Change the backend envelope. Card titles, summaries, source URLs, and image URLs all arrive pre-baked. Render what's given.
- Substitute the og:image with a different image source. If `image_url` is null OR the load fails, fall back to the category icon. Do not call out to a separate image service.
- Add new dependencies. SwiftUI's `AsyncImage` + SF Symbols + the existing brand-color tokens are sufficient.
- Touch `OrchetWatch/`. Watch app parity for cards is a separate brief.
- Bump deployment target above iOS 17.0.

**You MUST:**

- Add three new types in `Lumo/Models/SearchCards.swift`:

  ```swift
  struct SearchCard: Codable, Identifiable, Equatable {
      let id: String
      let title: String
      let summary: String
      let source_url: String
      let source_host: String
      let image_url: String?
      let category: String
      let category_icon: String
      let read_time_minutes: Int?
  }

  struct SearchCardsFrameValue: Codable, Equatable {
      let lead_story_index: Int?
      let cards: [SearchCard]
  }
  ```

  Snake-cased field names match the wire format; use a `CodingKeys` enum (or leave the snake_case property names as-is). Do NOT camel-case the Swift properties unless you also map the JSON keys.

- Add the new frame case to the SSE-decode enum in `Lumo/Services/ChatSSEDecoder.swift` (or wherever today's frame decoder lives — `grep -n 'case .summary' Lumo/`). Match shape to the existing `summary` / `selection` cases:

  ```swift
  case searchCards(SearchCardsFrameValue)
  // …
  case "search_cards":
      let v = try container.decode(SearchCardsFrameValue.self, forKey: .value)
      self = .searchCards(v)
  ```

- Add `searchCards: SearchCardsFrameValue?` to the chat message model (probably `Lumo/Models/ChatMessage.swift`) the way `summary` and `mission` already live on it.

- Build three SwiftUI views in `Lumo/Components/`:

  - `SearchResultCardStack.swift` — the dispatcher. Takes a `SearchCardsFrameValue`, picks featured vs equal-weight layout, mounts the right child views.
  - `FeaturedSearchCard.swift` — large hero (180pt on iPhone, 220pt on iPad), h2 title, fuller body, source-host + read-time row, full-card tap target.
  - `CompactSearchCard.swift` — used both as the equal-weight grid card and the featured-layout secondaries. Hero block is 84pt wide on the side (horizontal layout when nested under a featured card) or 96pt tall on top (grid layout).

- Build a small `CategoryThemes.swift` helper that mirrors `orchet-web/lib/search-cards-core.ts`'s `SEARCH_CARD_CATEGORY_THEME` — same hex values for `bg`, `icon`, `chipBg`, `chipText` per category, exposed as Swift `Color` instances. Categories: AI, Hardware, Maps, Finance, Sports, Weather, Music, News, Business, Science, Travel, World. Unknown category → World.

- Build a `CategoryIcon.swift` view that maps the server's `category_icon` string to an SF Symbol:

  | server | SF Symbol |
  |---|---|
  | sparkles | sparkles |
  | device-laptop | laptopcomputer |
  | map-2 | map |
  | chart-line | chart.line.uptrend.xyaxis |
  | ball-football | soccerball |
  | cloud | cloud |
  | music | music.note |
  | news | newspaper |
  | building-bank | building.columns |
  | briefcase | briefcase |
  | code | chevron.left.forwardslash.chevron.right |
  | world (default) | globe |

- Mount in `ChatView.swift`. After the existing assistant prose bubble for an assistant message, if `message.searchCards != nil`, render `SearchResultCardStack(value: message.searchCards!)`. Match the leading inset web uses (~18pt) so the cards sit under the prose, not against the message-bubble edge.

- Image rendering: use `AsyncImage(url: URL(string: card.image_url ?? ""))` with a placeholder that renders the category-icon fallback while loading AND on error. Do not block the layout on image load — set `frame(height: heroHeight)` and let the placeholder fill while the image arrives.

- Tap behavior: each card opens its `source_url` via `Link(destination:)` for normal http(s) URLs. Wrap the full card body in the Link so the tap target spans the whole card, not just the title.

---

## Deliverable: single PR to `orchet-ios`

**Title:** `ORCHET-IOS-PARITY-1A: SearchResultCard SwiftUI views + search_cards frame decoding`

### Part A — Codable models

1. `Lumo/Models/SearchCards.swift` with the two structs above.
2. Update the chat-frame SSE decoder to include the `search_cards` case.
3. Update the chat message model to include `searchCards: SearchCardsFrameValue?` plus an extension/initializer that pulls it off the SSE frame stream for the active assistant message.

### Part B — Theme + icon helpers

4. `Lumo/Components/SearchCards/CategoryThemes.swift` mirroring web's hex values.
5. `Lumo/Components/SearchCards/CategoryIcon.swift` mapping `category_icon` → SF Symbol.

### Part C — Card views

6. `Lumo/Components/SearchCards/FeaturedSearchCard.swift`.
7. `Lumo/Components/SearchCards/CompactSearchCard.swift`. Supports two layouts via an internal enum (`.gridCell` = vertical with top hero, `.featuredSecondary` = horizontal with left thumb).
8. `Lumo/Components/SearchCards/SearchResultCardStack.swift` — the dispatcher.
9. `Lumo/Components/SearchCards/SourcesFooter.swift` — pill chips of source hosts, matches web's footer.

### Part D — Integration

10. `ChatView.swift` mounts `SearchResultCardStack` below the assistant prose when present. Match the existing trailing-padding pattern used for `SuggestionChips` and `CompoundLegStrip`.

### Part E — Tests

11. `LumoTests/SearchCardsDecodeTests.swift` — decode a fixture JSON (capture from the orchet-backend `feat/search-cards-frame` SSE output for the Google releases prompt) and assert the model materializes the expected card count, lead index, and field values.
12. `LumoTests/SearchResultCardStackTests.swift` — snapshot or layout test that:
    - 3 cards, `lead_story_index = null` → equal-weight grid renders with all 3 visible.
    - 3 cards, `lead_story_index = 0` → featured card renders with the first card promoted, two secondaries below.
    - 1 card → renders as a single card (no grid, no featured layout).
    - 0 cards → renders nothing (safety).
13. `LumoTests/AsyncImageFallbackTests.swift` — verify the placeholder renders the category icon when `image_url` is nil.

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
2. Sign in. In the chat thread, ask "what are the latest updates on google's new releases yesterday?".
3. Verify: prose streams in, then ~1-2s after the stream ends, the cards appear inline below the prose. Featured card up top, two compact secondaries below, sources strip at the bottom.
4. Tap the featured card → opens `blog.google` (or whatever source the backend returned) in Safari.
5. Tap a source chip → opens that source.
6. Pull-to-refresh or restart the chat → on replay, cards should re-render from the persisted message state (verify the `searchCards` field survives session persistence).
7. Switch to dark mode → all category colors still readable.
8. iPad split-screen narrow → secondaries collapse to single column.
9. Slow-network simulator profile → AsyncImage placeholder shows the category icon during load; image swaps in when ready; on failure the icon stays.

Capture three Honeycomb permalinks filtered on `client.kind=ios`:
- `voice.outcome=executed` after a search-grounded turn
- Chat turn duration (verify rendering doesn't bloat first-paint)
- `search_cards` frame emission count for iOS clients

---

## Stop conditions (report, don't work around)

- **SSE decoder changes break existing tests** — the decoder may already use a discriminated-union pattern that doesn't tolerate a new case without exhaustiveness updates elsewhere. Find every match site (`grep -n '.summary' Lumo/`) and add the new case explicitly. STOP if it requires changing the SSE protocol contract.
- **`AsyncImage` fails on og:image URLs that require a User-Agent header** — some publisher CDNs reject default Swift UA. STOP and report. Fallback: do nothing — the category icon already covers this case. We will NOT add a custom image fetcher in this PR.
- **The backend envelope adds new fields after this brief was authored** — if `feat/search-cards-frame` has been updated and the wire format has extra fields not listed in this brief's `SearchCard` struct, just add the new fields as `let newField: Type?`. Don't break decode for backwards compatibility.
- **Category color hexes don't match between web and iOS** — they MUST match. The brief lists them indirectly via `orchet-web/lib/search-cards-core.ts`'s `SEARCH_CARD_CATEGORY_THEME` map. Read that file as the canonical source. Diverging is a brand bug.

---

## What "done" looks like

1. PR ready-for-review on `Orchet-AI/orchet-ios@main`.
2. CI green (xcodegen + xcodebuild build + xcodebuild test).
3. PR body includes:
   - Side-by-side screenshot of web and iOS rendering the same Google releases response. Cards should be visually identical modulo platform conventions (corner radius, font).
   - One real-device smoke transcript: ask "latest google news yesterday", see the cards land, tap one, return to chat with the chat state intact.
   - Snapshot tests for the three layout variants (equal-weight, featured, single-card).
4. Existing chat features still work — no regression on summary cards, mission cards, suggestion chips, compound dispatch.

---

## References

- [Backend PR — search_cards frame](https://github.com/Orchet-AI/orchet-backend/tree/feat/search-cards-frame)
  - `packages/domain-orchestrator/src/executor/search-cards.ts` — canonical envelope shape
  - `packages/data-access/src/repositories/events.ts` — frame type registry
- [Web PR — SearchResultCards](https://github.com/Orchet-AI/orchet-web/tree/feat/search-result-cards)
  - `lib/search-cards-core.ts` — shared types, theme map, icon map (THIS is the canonical color and icon source)
  - `components/SearchResultCards.tsx` — reference renderer; translate the responsive logic to SwiftUI
  - `app/page.tsx` — mount-point pattern (under assistant prose, in the same indented rail as suggestion chips)
- [ORCHET-IOS-PARITY-1 brief](./ORCHET-IOS-PARITY-1-CODEX-BRIEF.md) — sibling brief; shares the SSE decoder + ChatView surfaces
