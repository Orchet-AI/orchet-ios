import Foundation
import SwiftUI

/// Drives the iOS /cost surface. Mirrors web's
/// `apps/web/app/settings/cost/page.tsx` — budget caps, today + month
/// totals, recent agent activity. Single LoadState; pull-to-refresh.
@MainActor
final class CostScreenViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded(UserCostDashboard)
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let fetcher: CostFetching

    init(fetcher: CostFetching) {
        self.fetcher = fetcher
    }

    func loadIfNeeded() async {
        if case .loading = state { return }
        if case .loaded = state { return }
        await refresh()
    }

    func refresh() async {
        state = .loading
        do {
            state = .loaded(try await fetcher.fetchDashboard())
        } catch CostServiceError.unauthorized {
            state = .error("Sign in to view your spend.")
        } catch {
            state = .error("Couldn't load cost. Pull to refresh.")
        }
    }
}
