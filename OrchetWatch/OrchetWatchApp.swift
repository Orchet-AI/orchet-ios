import SwiftUI

/// Entry point for the OrchetWatch single-target watchOS companion app
/// (watchOS 7+ shape — no embedded WatchKit extension).
///
/// Phase 3 MVP: this app does NOT make any backend calls, does NOT
/// hold OAuth tokens, does NOT initiate payments, and does NOT touch
/// the keychain access group shared with the iPhone app. It renders a
/// static "open the iPhone app to continue" placeholder screen.
///
/// Phase 4 (planned, separate commit): a WatchConnectivity bridge so
/// the iPhone can push a small read-only app-status payload (no
/// secrets, no tokens) to the watch for at-a-glance display.
///
/// Naming: this is a NEW target carrying the post-rebrand "Orchet"
/// branding. The existing iOS app target stays "Lumo" / `com.lumo.rentals.ios`
/// pending the App-Store rebrand coordination, but new targets created
/// after the Lumo → Orchet pivot use the new name. The bundle ID for
/// this target stays under the `com.lumo.rentals.ios.*` prefix
/// (`com.lumo.rentals.ios.watchkitapp`) so the watch companion can pair
/// with the existing iOS app on real devices.
@main
struct OrchetWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
