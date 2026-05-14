import Foundation
import SwiftUI

/// Drives the iOS /workspace surface — five tabs mirroring the web
/// shell (Today / Content / Inbox / Co-pilot / Operations). V1.0
/// ships Today + Operations as real data; Content / Inbox /
/// Co-pilot are gated "shipping in v1.x" placeholders matching
/// web's v1.0 posture.
@MainActor
final class WorkspaceScreenViewModel: ObservableObject {
    enum TabID: String, CaseIterable, Identifiable {
        case today
        case content
        case inbox
        case copilot
        case operations
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .content: return "Content"
            case .inbox: return "Inbox"
            case .copilot: return "Co-pilot"
            case .operations: return "Operations"
            }
        }
    }

    enum LoadState<T: Equatable>: Equatable {
        case idle
        case loading
        case loaded(T)
        case error(String)
    }

    @Published var selectedTab: TabID = .today
    @Published private(set) var today: LoadState<WorkspaceTodayEnvelope> = .idle
    @Published private(set) var operations: LoadState<WorkspaceOperationsEnvelope> = .idle

    private let fetcher: WorkspaceFetching

    init(fetcher: WorkspaceFetching) {
        self.fetcher = fetcher
    }

    func loadTodayIfNeeded() async {
        if case .loading = today { return }
        if case .loaded = today { return }
        today = .loading
        do {
            today = .loaded(try await fetcher.fetchToday())
        } catch {
            today = .error("Couldn't load Today. Pull to refresh.")
        }
    }

    func refreshToday() async {
        today = .loading
        do {
            today = .loaded(try await fetcher.fetchToday())
        } catch {
            today = .error("Couldn't load Today. Pull to refresh.")
        }
    }

    func loadOperationsIfNeeded() async {
        if case .loading = operations { return }
        if case .loaded = operations { return }
        operations = .loading
        do {
            operations = .loaded(try await fetcher.fetchOperations())
        } catch {
            operations = .error("Couldn't load Operations. Pull to refresh.")
        }
    }

    func refreshOperations() async {
        operations = .loading
        do {
            operations = .loaded(try await fetcher.fetchOperations())
        } catch {
            operations = .error("Couldn't load Operations. Pull to refresh.")
        }
    }
}
