# Codex brief — ORCHET-IOS-PARITY-1C: composed_ui frame + cab/restaurant/grocery views

**Brief ID:** ORCHET-IOS-PARITY-1C-CODEX
**Parent brief:** [ORCHET-IOS-PARITY-1](./ORCHET-IOS-PARITY-1-CODEX-BRIEF.md)
**Sibling brief:** [ORCHET-IOS-PARITY-1A-SEARCH-CARDS](./ORCHET-IOS-PARITY-1A-SEARCH-CARDS-BRIEF.md) (already merged)
**Predecessors:** Web + backend PRs landed 2026-05-14:
  - `Orchet-AI/orchet-backend` — `feat/composed-ui-cab-restaurant-grocery` (UI catalog + Haiku composer + `composed_ui` SSE frame + Postgres migration 074)
  - `Orchet-AI/orchet-web` — `feat/composed-ui-cab-restaurant-grocery` (three card components + ComposedUI dispatcher + chat integration)
**Status:** Drafted 2026-05-14
**Owner:** Codex
**Reviewer:** Kalas + Claude
**Estimated effort:** 3-4 days
**Repo:** [Orchet-AI/orchet-ios](https://github.com/Orchet-AI/orchet-ios)

Add SwiftUI rendering for the new `composed_ui` SSE frame so iOS users see the same multi-task generative UI surface web users now see when a single chat turn dispatches two or more domain tools (cab + restaurant, grocery + ride, etc.). Pairs 1:1 with the React `<ComposedUI>` dispatcher + `CabOfferCard` / `RestaurantBookingCard` / `GroceryCartCard` shipped on web.

This brief is pure rendering + frame-decode + action-callback work. No new networking, no new backend changes.

---

## Predecessor gates

Do NOT start until ALL of the following are true:

1. `feat/composed-ui-cab-restaurant-grocery` merged to `Orchet-AI/orchet-backend@main` and deployed to Render.
2. `feat/composed-ui-cab-restaurant-grocery` merged to `Orchet-AI/orchet-web@main` and deployed to Vercel. Verify: in the web chat, run a prompt that triggers multiple tools in one turn (e.g. "book me an Uber to SFO and reserve a table at Nopa for tonight at 7pm") and confirm the cab + restaurant cards both render under the assistant prose.
3. Postgres migration `074_events_frame_type_composed_ui.sql` applied to prod Supabase (it was applied during backend PR build; verify with `select frame_type, count(*) from events where frame_type = 'composed_ui'`).
4. Honeycomb shows non-zero `composed_ui` frame emission rate over a 1h window.

If any are false: STOP. iOS rendering against an envelope that's not in production will desync.

---

## Goal

Decode the `composed_ui` SSE frame, model it as Swift types matching the backend envelope, render three new card views (cab offer, restaurant booking, grocery cart), and mount the dispatcher in `ChatView` below the assistant prose — stack layout by default, row layout for peer comparisons, two-column grid for 4+ sections. Card CTAs map to natural-language follow-up turns via the existing chat send-text path.

---

## Hard scope boundaries

**You MUST NOT:**

- Add networking. The composed UI arrives in the existing chat SSE stream. CTAs send a follow-up chat turn — no direct provider API calls.
- Change the backend envelope. The catalog, payload shapes, and section ordering all come from the backend.
- Add a fourth vertical. Web ships three (cab/restaurant/grocery). Match exactly. New verticals require a new catalog entry on the backend + a new component on web AND a new brief here.
- Substitute brand colors. Use `LumoTheme` tokens (the `lumo-fg`, `lumo-fg-low`, `lumo-bg`, `lumo-surface`, `lumo-hair`, `lumo-edge` palette) the same way `SearchResultCard*` views do today.
- Touch `OrchetWatch/`. Watch app parity is a separate brief.
- Bump deployment target above iOS 17.0.

**You MUST:**

- Add the Codable models in `Lumo/Models/ComposedUI.swift`:

  ```swift
  struct ComposedUISection: Codable, Equatable, Identifiable {
      let id = UUID()
      let component: String
      // Raw JSON props — decoded per-component below.
      let props: AnyJSON
      private enum CodingKeys: String, CodingKey { case component, props }
  }

  enum ComposedUILayout: String, Codable {
      case stack, row, tabs
  }

  struct ComposedUIFrameValue: Codable, Equatable {
      let layout: ComposedUILayout
      let sections: [ComposedUISection]
  }
  ```

  Where `AnyJSON` is a thin Codable wrapper around `[String: Any]` (you may already have one — `grep -n 'AnyJSON' Lumo/`). If not, mirror the pattern used by the existing SSE frame-value decoders.

- Add per-card payload structs (one per catalog entry — match field-for-field with `orchet-backend/packages/domain-orchestrator/src/ui-catalog/index.ts`):

  ```swift
  struct CabOfferPayload: Codable, Equatable {
      let provider: String         // uber | lyft | lumo_rentals | ola | rapido
      let region: String           // US | IN | GB | AE
      let currency: String?
      let pickup: CabAddress?
      let dropoff: CabAddress?
      let eta_minutes: Double?
      let surge_multiplier: Double?
      let options: [CabOption]
  }
  struct CabAddress: Codable, Equatable { let address: String? }
  struct CabOption: Codable, Equatable {
      let tier_name: String?
      let price: Double?
      let capacity: Int?
      let hailing: String?         // "now" | "scheduled"
  }

  struct RestaurantBookingPayload: Codable, Equatable {
      let restaurant_name: String
      let restaurant_id: String?
      let provider: String?        // opentable | resy | yelp | zomato | dineout
      let cuisine: String?
      let rating: Double?
      let slot_start: String       // ISO-8601
      let slot_end: String?
      let party_size: Int
      let address: String?
      let phone: String?
      let special_request_supported: Bool?
  }

  struct GroceryCartPayload: Codable, Equatable {
      let provider: String         // instacart | blinkit | zepto | amazon_fresh | swiggy_instamart
      let region: String?
      let currency: String
      let items: [GroceryItem]
      let subtotal: Double?
      let taxes: Double?
      let delivery_fee: Double?
      let total: Double
      let delivery_window_start: String?
      let delivery_window_end: String?
  }
  struct GroceryItem: Codable, Equatable, Identifiable {
      var id: String { id_ ?? UUID().uuidString }
      let id_: String?
      let name: String?
      let quantity: Double?
      let unit: String?
      let price: Double?
      let image_url: String?
      private enum CodingKeys: String, CodingKey {
          case id_ = "id", name, quantity, unit, price, image_url
      }
  }
  ```

- Add the new frame case to the SSE-decode enum in the file that owns chat frame decoding (`grep -n 'case .searchCards' Lumo/`). Match the shape of the existing `searchCards` case shipped in PARITY-1A:

  ```swift
  case composedUI(ComposedUIFrameValue)
  // …
  case "composed_ui":
      let v = try container.decode(ComposedUIFrameValue.self, forKey: .value)
      self = .composedUI(v)
  ```

- Add `composedUI: ComposedUIFrameValue?` to the chat message model (`Lumo/Models/ChatMessage.swift`) next to the existing `searchCards` field.

- Build three card views in `Lumo/Components/ComposedUI/`:

  - `CabOfferCardView.swift` — provider+region discriminated. Header has provider label + surge badge (US only, when `surge_multiplier > 1`) or GST chip (IN only). Pickup/dropoff address rows. Tier-list rows (vehicle + capacity + price); tap a tier to select. Footer button: `Book {tier}` — calls `onBook(tier)`.
  - `RestaurantBookingCardView.swift` — restaurant name + rating + cuisine + slot + party size. Optional `TextField` for special request when `special_request_supported == true`. Footer button: `Confirm reservation` — calls `onConfirm(specialRequest: String?)`.
  - `GroceryCartCardView.swift` — item list with stepper-style +/− buttons per row, auto-removes at quantity 0. Computed subtotal/taxes/delivery_fee/total. Delivery-window row. Footer button: `Place order · {total}` — calls `onPlaceOrder(items: [(id, quantity)])`.

- Build `ComposedUIView.swift` — the dispatcher. Takes a `ComposedUIFrameValue` and a `onAction(ComposedAction)` callback. Maps `section.component` to a view:

  ```swift
  enum ComposedAction {
      case cabBook(provider: String, tier: String)
      case restaurantConfirm(name: String, specialRequest: String?)
      case groceryPlaceOrder(provider: String, items: [(id: String, quantity: Double)])
  }
  ```

  Unknown component names are silently dropped (defense in depth on top of the backend payload_schema validation). Layout dispatch:
  - `.stack` → `VStack(spacing: 12)`.
  - `.row` → on iPhone compact: `VStack`; on regular width or iPad: `HStack` two-column.
  - `.tabs` → for now, 2-column `LazyVGrid`. A real tab strip can land in a follow-up.

  For each section, decode `section.props` into the matching payload struct via `JSONDecoder().decode(CabOfferPayload.self, from: try JSONEncoder().encode(section.props))`. Decode failure → silently drop that section (parity with web's `validateAgainstSchema` drop behavior).

- Mount in `ChatView.swift`. After the existing `SearchResultCardStack` mount, if `message.composedUI != nil`, render `ComposedUIView(frame: message.composedUI!, onAction: handleComposedAction)`. Match the `~18pt` leading inset already used for search cards and `CompoundLegStrip`.

- Wire `handleComposedAction` in the chat view-model. Translate each case into a natural-language follow-up `sendText(...)` call (matches the web `handleComposedAction` translation table verbatim, so backend behavior is symmetric):

  | Action | sendText |
  |---|---|
  | `.cabBook(provider, tier)` | `"Book the {tier} on {provider}."` |
  | `.restaurantConfirm(name, request)` | `"Confirm the reservation at {name}." + (request: " Special request: {request}.")` |
  | `.groceryPlaceOrder(provider, items)` | `"Place the {provider} order: {qty}× {id}, …."` |

- Persistence on reload. The `composed_ui` frame is persisted on the backend via the `events` table; `replayMessageToUI` on web extracts it from the history payload. The iOS history-decode path (`grep -n 'composedUI' Lumo/Services/`) must do the same — pull the field off the replay JSON and reattach to `ChatMessage`. Web shape-guards (`isComposedUIFrameValue`) silently null on malformed input; iOS must match — decode failure → log + drop, never crash the chat surface.

---

## Deliverable: single PR to `orchet-ios`

**Title:** `ORCHET-IOS-PARITY-1C: composed_ui frame + cab/restaurant/grocery SwiftUI views`

### Part A — Codable models

1. `Lumo/Models/ComposedUI.swift` — `ComposedUISection`, `ComposedUIFrameValue`, `ComposedUILayout`.
2. `Lumo/Models/ComposedUIPayloads.swift` — `CabOfferPayload`, `RestaurantBookingPayload`, `GroceryCartPayload` + their nested types.
3. Update the chat-frame SSE decoder to include the `composed_ui` case.
4. Update `ChatMessage` to include `composedUI: ComposedUIFrameValue?`.

### Part B — Card views

5. `Lumo/Components/ComposedUI/CabOfferCardView.swift`.
6. `Lumo/Components/ComposedUI/RestaurantBookingCardView.swift`.
7. `Lumo/Components/ComposedUI/GroceryCartCardView.swift`.

### Part C — Dispatcher + integration

8. `Lumo/Components/ComposedUI/ComposedUIView.swift` — the dispatcher with the layout switch and per-section decode + drop-on-invalid.
9. `ChatView.swift` mounts `ComposedUIView` below the assistant prose (and below `SearchResultCardStack` when both are present in the same turn).
10. Chat view-model `handleComposedAction` translation table → existing `sendText` path.

### Part D — Persistence on reload

11. History replay decoder pulls `composedUI` off the message JSON; reattach to `ChatMessage`.

### Part E — Tests

12. `LumoTests/ComposedUIDecodeTests.swift` — fixture-JSON tests:
    - Cab + restaurant in `.stack` → both sections decode, both views materialize.
    - Cab + grocery in `.row` → both sections decode, HStack layout on regular width.
    - Unknown component `"FooCard"` → silently dropped, valid siblings still render.
    - Cab section with missing `provider` → drops only that section, restaurant sibling stays.
13. `LumoTests/CabOfferCardViewTests.swift` — surge badge appears for `region=US, surge_multiplier=1.4`, GST chip for `region=IN`, tier-selection state.
14. `LumoTests/GroceryCartCardViewTests.swift` — quantity +/− buttons mutate state, total recomputes, item auto-removes at quantity 0, place-order callback fires with the post-mutation list.
15. `LumoTests/ComposedUIPersistenceTests.swift` — replay a captured chat-message JSON with `composedUI` present → `ChatMessage.composedUI` is non-nil and decodes the same way as the live SSE path.

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
2. Sign in. In the chat thread, ask: "Book me an Uber to SFO and reserve a table at Nopa for tonight at 7pm."
3. Verify: prose streams in, then ~1-2s after the stream ends, cab + restaurant cards render inline below the prose.
4. Tap a cab tier → button label updates to `Book {tier}`. Tap the button → chat thread sends the natural-language follow-up; orchestrator should respond with a booking confirmation card via the existing TripConfirmation surface (not part of this PR — just verify the message round-trips).
5. Type a special-request note in the restaurant card → tap Confirm reservation → chat thread sends `Confirm the reservation at {name}. Special request: {note}.`.
6. Ask: "Order milk, eggs, and bread from Instacart for delivery tomorrow morning." Verify the grocery cart materializes. Hit +/− on a row → quantity updates and total recomputes locally. Tap Place order → follow-up sent.
7. Pull-to-refresh or restart the chat → on replay, composed_ui cards should re-render from the persisted message state (verify the `composedUI` field survives session persistence end-to-end).
8. Switch to dark mode → all card surfaces and badges still readable.
9. iPad split-screen narrow → `.row` layout collapses to single column; `.tabs` layout stays two-column.

Capture three Honeycomb permalinks filtered on `client.kind=ios`:
- `composed_ui` frame emission count for iOS clients
- Chat turn duration (verify the composer adds <~1.5s to turn end-to-end; if it does, that's a backend issue, not iOS)
- CTA-follow-up turns (count chat turns that match the `"Book the … on …"` / `"Confirm the reservation at …"` / `"Place the … order: …"` prefix)

---

## Stop conditions (report, don't work around)

- **`AnyJSON` doesn't exist and the decoder pattern in the repo doesn't accept opaque-props sections** — report it. We can switch the per-section decode to a two-pass approach (first decode `component` discriminator, then decode the matching payload struct as a sibling of `props`), but that requires a backend-envelope tweak so STOP and report.
- **Backend envelope adds new catalog entries after this brief was authored** — if `orchet-backend/packages/domain-orchestrator/src/ui-catalog/index.ts` has more than three entries by the time you start, add the missing payload structs + views in this PR. The brief should not regress feature coverage.
- **Composer sections arrive with snake_case Swift won't decode** — keep snake_case property names on the payload structs (no `CodingKeys` remapping unless the field genuinely needs it like `GroceryItem.id_`). The web side uses snake_case verbatim.
- **A card view ends up taller than half the screen on iPhone SE 3rd-gen** — the grocery cart with 8+ items is the realistic worst case. Wrap the item list in a scrollable container only after testing — most carts will be 3-6 items and don't need scrolling.
- **The `composedUI` frame is being emitted but `ChatMessage.composedUI` stays nil** — the message-flush logic in the chat view-model probably forgot to thread the field through, same bug pattern as web's `replayMessageToUI` fix in PR #20. Check the SSE handler ALSO populates `composedUI` on the assistant message, not just the local accumulator.

---

## What "done" looks like

1. PR open against `Orchet-AI/orchet-ios@main` titled `ORCHET-IOS-PARITY-1C: composed_ui frame + cab/restaurant/grocery SwiftUI views`.
2. All listed Xcode test suites pass in CI.
3. Manual smoke screenshots attached: cab card, restaurant card, grocery card, multi-section stack, dark mode.
4. PR body links: this brief, the merged backend PR, the merged web PR, the Honeycomb permalinks above.
5. Reviewers (Kalas + Claude) tagged.
6. No new dependencies introduced. No `OrchetWatch/` changes. No `iOSDeploymentTarget` bump.
