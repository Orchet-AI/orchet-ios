# orchet-ios

The Orchet iOS app — a SwiftUI client that talks to the Orchet
gateway directly. No backend logic lives here; this repo is the iOS
shell only.

This repo is one of the post-split Orchet repositories. See
[Sibling repos](#sibling-repos) below for the full set.

## Architecture

```text
iPhone / iPad ─►  apps/ios (this repo)  ─►  Orchet gateway  ─►  services/*
                                              (sibling repo: orchet-backend)
```

The gateway URL is configured by the **`OrchetGatewayBase`**
Info.plist key (set from xcconfig). Production builds populate it;
the app's `AppConfig.gatewayBaseURL` reads it and every HTTP service
in `Lumo/Services/*` calls the gateway directly.

### iOS rollout history (relevant context)

- The pre-rollout iOS code had a runtime fallback to `apps/web`
  `/api/*` BFF proxies when `OrchetGatewayBase` was empty. That
  rollout cleared on 2026-05-07 (≥99% adoption + 7-day sustain).
- The web shell has since deleted the 24 IOS_COMPAT routes that
  served the fallback, so production iOS builds **must** have
  `OrchetGatewayBase` populated to function.
- Test fixtures under `LumoTests/*Tests.swift` still mock against
  the legacy `/api/*` URL shape (5 files, 29 hard-coded `"/api/"`
  strings). Production code in `Lumo/` has zero hard-coded `"/api/"`
  strings. The fixtures will be re-pointed to gateway URLs in a
  follow-up; they don't reach a live network so the legacy URL
  literals are harmless.

### Boundary rules

- ✅ **Allowed:** Calls to the Orchet gateway (`OrchetGatewayBase`),
  Supabase (Auth via the SwiftPM `Supabase` SDK), Stripe iOS SDK,
  Deepgram (token-minted via gateway).
- ❌ **No new `/api/` calls.** New endpoints belong on the gateway,
  not on apps/web. The 29 existing legacy strings are test fixtures
  only.
- ❌ **No source dependency on the monorepo.** Comments referencing
  `apps/web/...` paths are documentation context only — they describe
  where a feature lives in the sibling backend/web repos. There are
  no actual code imports.

## Setup

You need:
- macOS with Xcode 17+ (tested with Xcode 26.4.1).
- `xcodegen` from Homebrew: `brew install xcodegen`.

The Xcode project is **not committed** — it's regenerated from
`project.yml` by `xcodegen`. Run after cloning (and after any
`project.yml` edit):

```sh
xcodegen generate
open Lumo.xcodeproj
```

## Running against a custom backend

The app reads two keys from `Info.plist`, both populated from
xcconfig:

| Key | Purpose |
| --- | --- |
| `OrchetGatewayBase` | Gateway base URL — `https://gateway.orchet.app` in production. **Required for any non-local build to reach the backend.** |
| `LumoAPIBase` | Legacy apps/web BFF URL. Pre-rollout fallback target; not used in production runtime paths anymore. |

Plus the Supabase publics, Stripe test publishable key, and APNs
sandbox flag (also Info.plist via xcconfig).

For local dev, populate `Lumo.local.xcconfig` (gitignored — never
commit secrets) and run:

```sh
xcodegen generate
xcodebuild test \
  -project Lumo.xcodeproj \
  -scheme Lumo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Note on `ios-write-xcconfig.sh`

The pre-split monorepo had `scripts/ios-write-xcconfig.sh` at the
top level (one script for all engineers' local builds). The split
left this iOS repo with only `scripts/build-and-deploy-iphone.sh`;
the xcconfig generator is **not** in this repo today. Until it's
ported, populate `Lumo.local.xcconfig` manually or rely on the
empty defaults committed in `Lumo.xcconfig` — the app surfaces a
clean "auth/payments not configured" state rather than crashing.

Porting the xcconfig generator is a follow-up.

## Test status

`xcodebuild test -project Lumo.xcodeproj -scheme Lumo -destination
'platform=iOS Simulator,name=iPhone 17 Pro'` builds the app cleanly
but the test target hits a Swift 6 strict-concurrency compile error
in `LumoTests/AuthStateMachineTests.swift`:

```
main actor-isolated instance method 'currentAccessToken()' cannot
satisfy nonisolated requirement
```

The `final class FakeAuthService: AuthServicing` conformance is
`@MainActor` while the protocol's methods are nonisolated. **This
is a pre-existing source state** (byte-identical to the pre-split
monorepo's `apps/ios/LumoTests/AuthStateMachineTests.swift`); the
fix is iOS-team Swift work, not an extraction concern.

Expected fix shapes:
- Annotate `AuthServicing` protocol with `@MainActor`, OR
- Use `@preconcurrency` on the `FakeAuthService` conformance, OR
- Mark conforming method declarations `nonisolated`.

Until that's resolved, run individual non-Auth-related test classes
via `-only-testing:LumoTests/<SuiteName>` to validate other paths.

## Branding (intentionally Lumo today)

App name, bundle ID, Xcode target/scheme, and directory paths are
intentionally still `Lumo` / `com.lumo.rentals.*`:

- `name: Lumo` in `project.yml`
- `bundleIdPrefix: com.lumo.rentals` in `project.yml`
- `Lumo/` (Swift sources), `LumoTests/`
- `LumoApp` SwiftUI App struct
- `Lumo.xcconfig` filename

The rebrand to **Orchet** is **blocked on Apple Developer Portal
coordination** — provisioning profiles, push certificates, and
bundle ID re-registration. Once that's resolved, a single
coordinated commit will rename the project + bundle id + dir paths
+ Xcode files + the `LumoApp` struct atomically. New Orchet
branding (`OrchetGatewayBase`, `OrchetLockup`, voice catalog
naming) is already used inside the app where it doesn't cross the
Apple Developer boundary.

## Project shape

```
Lumo/                  Swift source: App/, Services/, ViewModels/,
                       Views/, Models/, Components/, Resources/.
LumoTests/             XCTest suites (AuthStateMachine, Chat,
                       CompoundStream, DeepgramToken, DrawerScreens,
                       Notification, Payment, …).
docs/                  iOS-specific docs (notes, Deepgram recon).
scripts/               build-and-deploy-iphone.sh.
project.yml            xcodegen project definition.
Lumo.xcconfig          Committed defaults; #include?'s gitignored
                       Lumo.local.xcconfig for secrets.
ARCHITECTURE.md        Lumo iOS architecture overview.
```

## Sibling repos

| Repo | Role |
| --- | --- |
| **`orchet-ios`** (this repo) | SwiftUI iOS client. |
| `orchet-backend` | Services, domain packages, OpenAPI, infra, ML brain. The gateway lives here. |
| `orchet-web` | Next.js web frontend. Hits the same gateway. |
| `orchet-android` | Stub. Future Kotlin/Compose client (Android team). |
| `orchet-mcp` | MCP hub. Reached by `services/mcp-client/` in orchet-backend over HTTP. |
| `orchet-brand` | Tailwind + Swift design tokens, logos, design system. |

The split was extracted from a pre-split monorepo (tagged
`v0.1.0-before-repo-split` on the source remote at commit
`610c486`).

## Help / feedback

- File issues against this repo with the `ios` label.
- Backend, gateway, and domain issues belong in `orchet-backend`.
- Brand/asset/icon issues belong in `orchet-brand`.
