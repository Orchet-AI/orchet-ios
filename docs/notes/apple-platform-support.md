# Apple platform support — orchet-ios

What this iOS repo supports today, what's planned, and what the
phased rollout sequenced.

## Current state (2026-05-10)

| Platform / target | Status | Source-of-truth |
| --- | --- | --- |
| iPhone | **Supported.** Primary target. Min iOS 17.0. | `project.yml` `targets.Lumo` (`SDKROOT: iphoneos`, `IPHONEOS_DEPLOYMENT_TARGET: "17.0"`) |
| iPad | **Supported (universal).** Same `Lumo` target builds for iPad — no separate iPad-only target. | `project.yml` `targets.Lumo.settings.base.TARGETED_DEVICE_FAMILY: "1,2"` (1 = iPhone, 2 = iPad). `Lumo/Resources/Info.plist` carries `UISupportedInterfaceOrientations~ipad` for iPad-specific orientation handling. |
| Mac Catalyst | Not enabled. | `SUPPORTS_MACCATALYST: NO` in `project.yml` |
| Mac (Designed for iPhone/iPad) | Not enabled. | `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO` in `project.yml` |
| watchOS companion | Future (Phase 3 — pending). | n/a |
| visionOS / tvOS | Not planned. | n/a |

## Bundle IDs

The bundle-identifier scheme is locked to the `com.lumo.rentals` prefix
until the Lumo → Orchet App Store rebrand (Apple Developer Portal
coordination required; out of scope for code changes). Current pattern:

| Variant | Bundle ID |
| --- | --- |
| Release iOS app | `com.lumo.rentals.ios` |
| Debug iOS app | `com.lumo.rentals.ios.dev` |
| Tests | `com.lumo.rentals.ios.tests` |

## iPad — verification (commit `3bf6f03`+)

iPad support has been on since the project's xcconfig bootstrap
(`TARGETED_DEVICE_FAMILY: "1,2"`); the universal app builds clean on
iPad simulators today. Verified:

```sh
xcodegen generate
xcodebuild build \
  -project Lumo.xcodeproj \
  -scheme Lumo \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
# → BUILD SUCCEEDED, exit 0
```

`iPad Pro 13-inch (M5)` is the M5-era generation present on macOS 26 +
Xcode 26.4.1; older runners may carry `iPad Pro 13-inch (M4)` instead.
Either works because the `Lumo` target builds for any iPad in the
`1,2` family.

No SwiftUI layout work was needed for the audit — the app already uses
`SwiftUI` views with no explicitly hardcoded narrow-width frames in the
hot paths. iPad-specific UX polish (split view, larger detail panes,
multi-column layouts) is a separate body of work; this audit only
confirms iPad is structurally supported and builds clean.

## CI

The `.github/workflows/ci.yml` workflow runs the test suite against
**iPhone 16 Pro simulator** (`macos-15` runner). iPad is not in CI
today — tests are device-family-agnostic, so adding an iPad
destination would mostly duplicate runtime. Add later if iPad-specific
regressions surface.

## Code signing posture

`CODE_SIGNING_ALLOWED: NO` across the project for the entire test +
build matrix. This makes simulator-only builds work without
provisioning profiles or a Developer Portal seat. Real-device install
(TestFlight, App Store) requires:

- Apple Developer Portal team enrollment.
- Provisioning profile per bundle ID.
- For watchOS: separate provisioning for the `*.watchkitapp` bundle.

These are App-Store-rebrand-blocked alongside the Lumo → Orchet
rename — see the [orchet-backend canonical doc](https://github.com/Orchet-AI/orchet-backend/blob/main/docs/architecture/canonical.md)
for the broader coordination plan.

## Roadmap

| Phase | Scope |
| --- | --- |
| 1 | Audit (this doc) ✓ |
| 2 | Confirm iPad already works ✓ |
| 3 | Add watchOS companion app target — minimal SwiftUI MVP, simulator-only build |
| 4 | WatchConnectivity bridge (iPhone → Watch app-status payload, display-only) |
| Future | iPad-specific UX polish, Mac Catalyst evaluation, App Store rename |
