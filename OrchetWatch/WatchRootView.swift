import SwiftUI

/// Phase 3 MVP root view for the watchOS companion. Display-only.
/// No network, no OAuth, no payments, no keychain — see
/// OrchetWatchApp docstring for the contract.
///
/// The eventual UX (Phase 4+) will surface the most recent trip,
/// upcoming bookings, or a "tap to talk to the assistant on iPhone"
/// hand-off — driven by a WatchConnectivity payload from the paired
/// iPhone.
struct WatchRootView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Orchet")
                    .font(.title3.weight(.semibold))

                Text("Watch app")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 4)

                Text("Open the Orchet app on your iPhone to start a conversation, plan a trip, or review recent bookings.")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Text("Live status from your iPhone will appear here in a future update.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }
}

#Preview {
    WatchRootView()
}
