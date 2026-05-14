import Foundation
import SwiftUI

/// State machine for the reader-mode sheet. Pair to `ChatView`:
/// chat tap-handler calls `open(card:)`, sheet mounts on
/// `activeCard != nil`, dismisses via `close()`.
@MainActor
final class ReaderSheetController: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(SearchCard)
        case ready(SearchCard, ReaderArticle)
        case error(SearchCard, ReaderServiceError)

        var card: SearchCard? {
            switch self {
            case .idle: return nil
            case .loading(let c), .ready(let c, _), .error(let c, _): return c
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// SwiftUI `.sheet(item:)` needs a published Binding<SearchCard?>.
    /// Mirrors `state.card` so the sheet auto-mounts/dismisses when
    /// the state machine transitions. Setting it back to nil from
    /// the sheet dismissal triggers `close()`.
    var activeCard: SearchCard? {
        get { state.card }
        set {
            if newValue == nil { close() }
        }
    }

    private let service: ReaderFetching
    private var fetchTask: Task<Void, Never>?

    init(service: ReaderFetching) {
        self.service = service
    }

    func open(card: SearchCard) {
        fetchTask?.cancel()
        state = .loading(card)
        let svc = service
        fetchTask = Task { [weak self] in
            do {
                let article = try await svc.fetchArticle(url: card.sourceURL)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if case .loading(let c) = self.state, c.id == card.id {
                        self.state = .ready(card, article)
                    }
                }
            } catch let err as ReaderServiceError {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if case .loading(let c) = self.state, c.id == card.id {
                        self.state = .error(card, err)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if case .loading(let c) = self.state, c.id == card.id {
                        self.state = .error(card, .transport(String(describing: error)))
                    }
                }
            }
        }
    }

    func close() {
        fetchTask?.cancel()
        fetchTask = nil
        state = .idle
    }
}
