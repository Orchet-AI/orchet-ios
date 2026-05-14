import Foundation
import SwiftUI

/// Drives the /intents surface. Mirrors web's
/// `apps/web/app/intents/page.tsx`: list, toggle pause/resume,
/// delete, create minimal routine (description + cron + timezone).
@MainActor
final class IntentsScreenViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded([StandingIntent])
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published var busyID: String?
    @Published var createError: String?

    private let fetcher: IntentsFetching

    init(fetcher: IntentsFetching) {
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
            state = .loaded(try await fetcher.listIntents())
        } catch IntentsServiceError.unauthorized {
            state = .error("Sign in to view your routines.")
        } catch {
            state = .error("Couldn't load your routines.")
        }
    }

    func toggle(_ intent: StandingIntent) async {
        guard busyID == nil else { return }
        busyID = intent.id
        defer { busyID = nil }
        do {
            let updated = try await fetcher.setEnabled(id: intent.id, enabled: !intent.enabled)
            replace(intent: updated)
        } catch {
            // Force a fresh fetch so the toggle reflects server state
            // if a partial mutation slipped through.
            await refresh()
        }
    }

    func delete(_ intent: StandingIntent) async {
        guard busyID == nil else { return }
        busyID = intent.id
        defer { busyID = nil }
        do {
            try await fetcher.deleteIntent(id: intent.id)
            remove(id: intent.id)
        } catch {
            await refresh()
        }
    }

    func createIntent(
        description: String,
        cron: String,
        timezone: String
    ) async -> Bool {
        createError = nil
        let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCron = cron.trimmingCharacters(in: .whitespaces)
        guard !trimmedDesc.isEmpty, !trimmedCron.isEmpty else {
            createError = "Description and schedule are required."
            return false
        }
        do {
            let intent = try await fetcher.createIntent(
                description: trimmedDesc,
                schedule_cron: trimmedCron,
                timezone: timezone
            )
            prepend(intent: intent)
            return true
        } catch IntentsServiceError.validation(let detail) {
            createError = detail
            return false
        } catch {
            createError = "Couldn't create routine. Try again."
            return false
        }
    }

    // MARK: - Helpers

    private func replace(intent: StandingIntent) {
        guard case .loaded(let list) = state else { return }
        state = .loaded(list.map { $0.id == intent.id ? intent : $0 })
    }

    private func remove(id: String) {
        guard case .loaded(let list) = state else { return }
        state = .loaded(list.filter { $0.id != id })
    }

    private func prepend(intent: StandingIntent) {
        guard case .loaded(let list) = state else {
            state = .loaded([intent])
            return
        }
        state = .loaded([intent] + list)
    }
}
