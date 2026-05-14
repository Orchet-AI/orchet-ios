# Codex brief — ORCHET-IOS-PARITY-1B: ReaderDrawer SwiftUI sheet

**Brief ID:** ORCHET-IOS-PARITY-1B-CODEX
**Parent brief:** [ORCHET-IOS-PARITY-1A](./ORCHET-IOS-PARITY-1A-SEARCH-CARDS-BRIEF.md)
**Predecessors:** Web + backend PRs merged 2026-05-14:
  - `Orchet-AI/orchet-backend` — `feat/reader-mode-endpoint` (provides `GET /orchestrator/reader`)
  - `Orchet-AI/orchet-web` — `feat/reader-mode-drawer` (reference implementation of the side panel)
**Status:** Drafted 2026-05-14
**Owner:** Codex
**Reviewer:** Kalas + Claude
**Estimated effort:** 1–2 days
**Repo:** [Orchet-AI/orchet-ios](https://github.com/Orchet-AI/orchet-ios)

Card taps in `SearchResultCardStack` currently open `source_url` via `Link(destination:)`, jumping the user out to Safari. The product philosophy is one-app-controls-everything, so we replace that with a reader-mode sheet that renders the article inline. Pairs 1:1 with the web `ReaderDrawer` shipped on 2026-05-14.

---

## Predecessor gates

Do NOT start until ALL of the following are true:

1. `feat/reader-mode-endpoint` merged to `Orchet-AI/orchet-backend@main` and deployed to Render. Verify: `curl https://api.orchet.ai/orchestrator/reader?url=https://blog.google` returns JSON with `ok: true, article: {...}`.
2. `feat/reader-mode-drawer` merged to `Orchet-AI/orchet-web@main`. Verify on orchet.ai by clicking any search card — drawer slides in from the right.
3. iOS `feat/search-result-cards` is on `main` (PR #4 + follow-up #5 both merged — already done as of 2026-05-13).

If any gate fails: STOP and report.

---

## Goal

Replace the `Link(destination:)` wrappers in `FeaturedSearchCard`, `CompactSearchCard`, and `SearchCardsSourcesFooter` with tap-handlers that open a SwiftUI sheet rendering the article extracted by the backend's reader-mode endpoint.

---

## Hard scope boundaries

**You MUST NOT:**

- Add networking outside the existing chat-service shape. The reader endpoint is just another orchet-backend GET; wire it through `ChatService` or a new tiny `ReaderService` alongside it. Do NOT add a new networking framework.
- Render the article via `WKWebView` with `loadHTMLString`. Use a SwiftUI-native renderer (`AttributedString` with HTML parsing, or `Markdown` after a tiny html→md conversion). WKWebView pulls in a full browser engine for what's structured article text — overkill.
- Change the backend envelope. The endpoint returns `{ ok, article: { title, byline, lead_image_url, content_html, content_text, source_host, source_url, excerpt, published_date } }`. Match exactly.
- Bump iOS deployment target above 17.0.

**You MUST:**

- Add `Lumo/Models/ReaderArticle.swift` with the Codable struct matching the backend envelope. Snake-cased JSON keys mapped via `CodingKeys`.
- Add `Lumo/Services/ReaderService.swift` with one method: `func fetchArticle(url: String, jwt: String) async throws -> ReaderArticle`. Hits `GET ${OrchetAPIBase}/orchestrator/reader?url=...` with the Supabase bearer JWT. 8s timeout (the backend's own timeout is 4s plus cache-miss overhead). On non-2xx or decode-fail, throw `ReaderServiceError.{timeout, fetchFailed, parseFailed, blockedUrl}`.
- Add `Lumo/Components/ReaderSheet.swift` — the SwiftUI sheet view. Layout matches web 1:1:
  - Header: `source_host` label + `Open in Safari` button (SF Symbol `safari`) + close button (`xmark`). Header has a thin bottom border.
  - Body (scrollable):
    - Hero `AsyncImage(url: article.lead_image_url)` with `RoundedRectangle` mask + the category-themed fallback from `CategoryIconView` if image is nil or load fails. Aspect ratio 16:9, max height 220.
    - `Text(article.title)` as headline (system 22pt, weight .medium, leading lineSpacing 2).
    - Byline + published-date row in `.caption.foregroundStyle(.secondary)` if either is present.
    - Body content: use `try? AttributedString(markdown:)` after converting the `content_html` via a simple regex-based html→md transform (drop `<p>`, replace `<br>` with `\n\n`, etc.). If conversion fails, fall back to `Text(article.content_text)` in plain prose.
  - Loading state: a small `ProgressView` centered in the body region.
  - Error state: message + `Button("Open in Safari")` that triggers `UIApplication.shared.open(url)`.
- Add a `ReaderSheetState` enum (`.idle, .loading(SearchCard), .ready(SearchCard, ReaderArticle), .error(SearchCard, ReaderServiceError)`) and a `@MainActor @StateObject final class ReaderSheetController: ObservableObject` that owns the state, exposes `open(card:)` + `close()`, and runs the async fetch via `Task`. Place in `Lumo/ViewModels/ReaderSheetController.swift`.
- Modify `FeaturedSearchCard`, `CompactSearchCard`, and `SearchCardsSourcesFooter` to remove the `Link(destination:)` wrappers and replace with `Button(action: { onTap(card) })` calls. Add `let onTap: (SearchCard) -> Void` parameter to each. `SearchResultCardStack` accepts an `onCardTap: (SearchCard) -> Void` and threads it to children.
- In `ChatView.swift`, instantiate `ReaderSheetController` as `@StateObject`, pass `controller.open` as `onCardTap` to the `SearchResultCardStack`, and mount the sheet via `.sheet(item: $controller.activeCard)` (where `activeCard` is a Binding<SearchCard?> derived from the controller's state).

---

## Deliverable: single PR to `orchet-ios`

**Title:** `ORCHET-IOS-PARITY-1B: ReaderSheet SwiftUI views + reader-service wiring`

### Part A — Model + service

1. `Lumo/Models/ReaderArticle.swift` — Codable struct.
2. `Lumo/Services/ReaderService.swift` — `fetchArticle` method, 8s timeout, errors enumerated.

### Part B — Sheet view + controller

3. `Lumo/ViewModels/ReaderSheetController.swift` — state machine + Task management.
4. `Lumo/Components/ReaderSheet.swift` — the sheet UI.
5. `Lumo/Components/ReaderArticleBody.swift` — extracted body renderer (html→md→AttributedString) so we can unit-test the conversion separately.

### Part C — Card wiring

6. Modify `FeaturedSearchCard.swift`, `CompactSearchCard.swift`, `SearchResultCardStack.swift`, `SourcesFooter.swift` (rename `Sources` source-file if needed) to remove `Link(destination:)` and add `onTap` callbacks.
7. Modify `ChatView.swift` to instantiate the controller and mount the sheet.

### Part D — Tests

8. `LumoTests/ReaderArticleDecodeTests.swift` — decode fixture matching backend envelope; assert all fields, null-handling for optional fields.
9. `LumoTests/ReaderArticleBodyTests.swift` — html→md→AttributedString conversion: paragraphs, links, headings, images, code blocks all render correctly.
10. `LumoTests/ReaderSheetControllerTests.swift` — fake `ReaderService`, drive controller through `.idle → .loading → .ready` and `.idle → .loading → .error` paths.

---

## Verification

```bash
xcodegen generate
xcodebuild build -scheme Lumo \
                 -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
                 CODE_SIGNING_ALLOWED=NO
xcodebuild test  -scheme Lumo \
                 -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
                 CODE_SIGNING_ALLOWED=NO
```

All three must pass.

Manual smoke (do BEFORE marking PR ready-for-review; capture screenshots in the PR body):

1. Build to simulator + real device.
2. Sign in. Ask "any tech news today". Cards land.
3. Tap a card → sheet slides up with the article. Title, hero image, byline, body all render. **No Safari jump.**
4. Tap a source chip in the footer → same sheet opens.
5. Tap "Open in Safari" in the sheet → THEN it jumps to Safari (intended escape hatch).
6. Tap close → sheet dismisses.
7. Try with a known frame-blocking source (a New York Times URL) — the article still renders because we don't iframe.
8. Try with a URL the backend's reader can't parse (e.g. a YouTube link) — error state renders with "Open in Safari" fallback.
9. Pull-to-refresh on the article — should re-fetch (nice-to-have, not required for v1).
10. iPad: sheet renders as a proper sheet (default iPad sheet style); landscape rotation works.

---

## Stop conditions (report, don't work around)

- **`content_html` contains constructs `AttributedString(markdown:)` can't parse.** Some articles ship with complex inline styles, `<figure>`/`<figcaption>`, table tags. Fall back to `Text(article.content_text)` plain text — already in the brief. Don't expand the html→md converter into a full HTML parser.
- **`AsyncImage` fails on og:image URLs requiring a User-Agent.** Same as PARITY-1A — fall back to the category icon; do NOT add a custom image fetcher.
- **Backend endpoint returns 5xx on a specific source.** That's the backend's problem; surface the error in the sheet with the "Open in Safari" fallback. Don't iframe as a workaround.
- **Sheet performance issue on very long articles.** SwiftUI `Text` with large attributed strings can be slow on iOS 17. If you observe stutter, switch to `ScrollView { LazyVStack { ... } }` paragraph-by-paragraph. Document the choice.

---

## What "done" looks like

1. PR ready-for-review on `Orchet-AI/orchet-ios@main`.
2. CI green.
3. PR body includes:
   - Side-by-side screenshot of web ReaderDrawer + iOS ReaderSheet rendering the same article. Visually consistent (modulo platform conventions for sheet chrome).
   - One real-device smoke transcript: ask the chat, tap a card, read the article, close, ask another question.
   - Snapshot tests for `.loading`, `.ready`, `.error` states.
4. Existing chat features still work — voice transcript, summary cards, suggestion chips, compound dispatch, search cards on web's prior fixture.

---

## References

- [Backend PR — reader-mode endpoint](https://github.com/Orchet-AI/orchet-backend/tree/feat/reader-mode-endpoint)
  - `services/orchestrator/src/routes/reader.ts` — canonical envelope shape + SSRF guard rules
- [Web PR — reader-mode drawer](https://github.com/Orchet-AI/orchet-web/tree/feat/reader-mode-drawer)
  - `lib/use-reader-drawer.ts` — state machine reference
  - `components/ReaderDrawer.tsx` — visual reference, copy layout decisions
  - `app/page.tsx` — mount-point pattern
- [ORCHET-IOS-PARITY-1A](./ORCHET-IOS-PARITY-1A-SEARCH-CARDS-BRIEF.md) — sibling brief, shares ChatView surfaces
- [@mozilla/readability output schema](https://github.com/mozilla/readability) — for understanding `content_html` shape
