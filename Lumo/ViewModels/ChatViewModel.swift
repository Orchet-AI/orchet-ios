import Combine
import Foundation
import SwiftUI

/// Owns the chat list state machine. The view binds to `messages`,
/// `input`, `error`, and `isStreaming`; everything else (status
/// transitions, retry, regenerate, cancellation on view teardown) is
/// driven from here.
///
/// State machine per message:
///   user:      sending → sent → (delivered if needed) | failed
///   assistant: streaming → delivered | failed
///
/// `lastUserPrompt` lets `regenerate()` re-issue the previous prompt
/// without requiring the user to retype.

/// How the current turn was initiated. Drives whether the assistant
/// response gets read back via TTS:
///   .text  — user typed; render text only.
///   .voice — user spoke; speak the response back.
///   .both  — accessibility / mixed-input mode; render AND speak.
enum VoiceMode: String {
    case text
    case voice
    case both

    /// Whether this turn should produce TTS output.
    var shouldSpeak: Bool {
        self == .voice || self == .both
    }
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published private(set) var error: String?
    @Published private(set) var isStreaming: Bool = false

    /// First-token latency from `send()` to the first non-empty
    /// `.text` SSE frame, in seconds. Reset on every send. Used by
    /// the voice-mode latency probe in `scripts/ios-measure-perf.sh`
    /// — surfaced through a debug-only HUD (Phase 5 perf observability).
    @Published private(set) var lastFirstTokenLatency: TimeInterval?

    /// Per-turn suggested-reply chips. Keyed by the server's
    /// `turn_id` so historical replay can reattach chips to the
    /// matching assistant message without re-streaming. The view
    /// only renders chips for the LAST assistant message before any
    /// user message (matching web's stale-suppression rule), so older
    /// turns naturally fall out of the strip without any explicit
    /// expiration.
    @Published private(set) var suggestionsByTurn: [String: [AssistantSuggestion]] = [:]

    /// Per-assistant-message interactive selections (flight offers
    /// today, food/time slots in follow-up sprints). Keyed by the
    /// assistant message UUID — the SSE handler attaches selections
    /// to the in-flight assistant bubble when the frame arrives.
    /// Same stale-suppression rule as suggestions: the view only
    /// renders selections for an assistant message that has no
    /// user message after it, mirroring web's `userMessageExistsAfter`.
    @Published private(set) var selectionsByMessage: [UUID: [InteractiveSelection]] = [:]

    /// Per-assistant-message confirmation summaries (the money-gate
    /// `summary` SSE frame — flight itineraries today; trips,
    /// reservations, carts in follow-up sprints). The card stays
    /// visible after the user confirms or cancels: the user message
    /// they sent ("Yes, book it." / "Cancel — don't book that.")
    /// flips it into a decided-label state, but the summary itself
    /// stays in the cache so the rendered card preserves its
    /// terminal copy. Mirrors web's `userMessageExistsAfter(m.id)`
    /// → decidedLabel pattern in apps/web/app/page.tsx.
    @Published private(set) var summariesByMessage: [UUID: ConfirmationSummary] = [:]

    /// Per-assistant-message compound-dispatch payloads (the
    /// `assistant_compound_dispatch` SSE frame — multi-agent trip
    /// orchestration). Like summary cards, the strip stays visible
    /// after the user moves on: the live URLSession subscription
    /// closes when all legs reach terminal status, and the strip
    /// renders as a static settled record.
    @Published private(set) var compoundDispatchByMessage: [UUID: CompoundDispatchPayload] = [:]
    /// SearchResultCard envelope keyed by the assistant message id.
    /// Mirrors web's `UIMessage.searchCards`. The orchestrator emits
    /// the `search_cards` SSE frame after the prose stream completes
    /// for turns that grounded their answer in web_search; ChatView
    /// renders `SearchResultCardStack` below the prose when this
    /// dict has an entry for the message.
    @Published private(set) var searchCardsByMessage: [UUID: SearchCardsFrameValue] = [:]

    /// PARITY-1C — composed_ui frame value attached per assistant
    /// turn. Same lifecycle as `searchCardsByMessage`: cleared on
    /// reset/loadSession, replaced on re-emission, persisted via
    /// the replay decoder.
    @Published private(set) var composedUIByMessage: [UUID: ComposedUIFrameValue] = [:]

    /// PARITY-1D — inline OAuth-connect cards. The orchestrator emits
    /// a `connection_required` frame when a tool dispatch returns
    /// `code: "connection_required"` and the backend successfully
    /// minted an authorize URL. iOS opens it via
    /// `ASWebAuthenticationSession`. After completion we auto-send a
    /// follow-up so the orchestrator retries the original tool.
    @Published private(set) var connectionRequiredByMessage: [UUID: ConnectionRequiredFrameValue] = [:]

    /// Per-agent_id dedup so a user who taps Connect twice doesn't
    /// fire two auto-retry turns. Mirrors web's
    /// `retriedConnectionAgentIds`.
    private var retriedConnectionAgentIds: Set<String> = []
    /// Per-leg status overrides keyed by compound_transaction_id.
    /// Per-leg updates arrive via the per-compound stream and merge
    /// into the inner dictionary (leg_id → latest status). The view
    /// reads the override layered over the dispatch payload's
    /// initial status.
    @Published private(set) var compoundLegStatusOverrides: [String: [String: CompoundLegStatus]] = [:]

    /// Per-leg metadata captured from leg-status SSE updates —
    /// status-change timestamps + provider_reference + evidence
    /// dict. Keyed `compound_transaction_id → leg_id → CompoundLegMetadata`.
    /// The detail panel reads this to render booking refs,
    /// elapsed-time tickers, and failure reasons.
    @Published private(set) var compoundLegMetadata: [String: [String: CompoundLegMetadata]] = [:]

    /// Set of leg_ids currently expanded in the dispatch strip's
    /// detail panel. Multiple legs can be expanded simultaneously
    /// across re-renders (the user may want to compare two in-flight
    /// legs side by side). Toggled via
    /// `toggleCompoundLegDetail(legID:)`.
    @Published private(set) var compoundLegDetailExpandedFor: Set<String> = []

    /// Optional subscription handle for live per-leg updates.
    /// Injected by RootView so test paths can pass a no-op or fake.
    private let compoundStreamService: CompoundStreamService?
    /// Active per-compound subscription tasks, keyed by
    /// compound_transaction_id. Cancelled on reset() and on
    /// terminal compound state.
    private var compoundStreamTasks: [String: Task<Void, Never>] = [:]

    private let service: ChatService
    /// Mutable so MOBILE-CHAT-LOAD-SESSION-1's `loadSession(id:)`
    /// can swap to an older conversation. Otherwise functions like
    /// a `let` since `send()` and friends never reassign it.
    private var sessionID: String
    private let tts: TextToSpeechServicing?
    private var streamingTask: Task<Void, Never>?
    private var lastUserPrompt: String?
    private var lastVoiceMode: VoiceMode = .text
    /// Captured at the moment send() begins so we can record
    /// first-token latency on the matching .text event.
    private var streamStartTime: Date?

    // ORCHET-IOS-PARITY-1 — streaming voice transcript wiring.
    //
    // The `(turn_id, message_id)` pair tracks the in-flight assistant
    // bubble being assembled from `voice_assistant_transcript_delta`
    // messages. When `turn_id` is missing on the wire (best effort
    // from the voice service), we still keep a single in-flight
    // bubble keyed by "no-turn" so deltas concatenate cleanly.
    private var streamingVoiceCancellables = Set<AnyCancellable>()
    private var inflightAssistantTurnKey: String?
    private var inflightAssistantMessageID: UUID?

    init(
        service: ChatService,
        sessionID: String = UUID().uuidString,
        tts: TextToSpeechServicing? = nil,
        compoundStreamService: CompoundStreamService? = nil,
        historyFetcher: DrawerScreensFetching? = nil
    ) {
        self.service = service
        self.sessionID = sessionID
        self.tts = tts
        self.compoundStreamService = compoundStreamService
        self.historyFetcher = historyFetcher
    }

    /// Optional injection used by MOBILE-CHAT-LOAD-SESSION-1 to
    /// replay an older session's messages. When nil, `loadSession`
    /// is a no-op.
    private let historyFetcher: DrawerScreensFetching?

    func send(mode: VoiceMode = .text) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        input = ""
        lastVoiceMode = mode
        // ORCHET-IOS-MEMORY-LEARNING Phase A — captures only the
        // mode discriminator, never the prompt text. The backend
        // already learns from the prompt via the chat turn pipeline;
        // this signal exists so the fact extractor can cohort by
        // time-of-day / mode usage without re-reading turns.
        BehaviourSignalService.shared.record(
            kind: .chatTurnSent,
            attributes: ["mode": .string(mode.rawValue)]
        )
        startStream(prompt: text, addUserBubble: true)
    }

    /// Convenience entry point used by the voice composer — pushes
    /// the transcript directly into the input field and sends in
    /// voice mode without a tap on the text field.
    func sendVoiceTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        input = trimmed
        send(mode: .voice)
    }

    /// Submit a suggestion chip's `value` as if the user had typed
    /// it. Mirrors the web behaviour where chip-tap and typed reply
    /// are indistinguishable downstream — the chip's `label` is only
    /// the chip face, never the submitted text. Suggestions clear
    /// implicitly because the rendering rule hides chips on any
    /// assistant message that has a user message after it.
    func sendSuggestion(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        lastVoiceMode = .text
        startStream(prompt: trimmed, addUserBubble: true)
    }

    /// PARITY-1C — turn a composed-UI gesture into a follow-up
    /// natural-language turn. Translation table mirrors web's
    /// `handleComposedAction` verbatim so the orchestrator's flow
    /// controller sees the same prompt regardless of client.
    func handleComposedAction(_ action: ComposedAction) {
        let prompt: String
        switch action {
        case .cabBook(let provider, let tier):
            prompt = "Book the \(tier) on \(provider)."
        case .restaurantConfirm(let name, let request):
            if let request, !request.trimmingCharacters(in: .whitespaces).isEmpty {
                prompt = "Confirm the reservation at \(name). Special request: \(request)."
            } else {
                prompt = "Confirm the reservation at \(name)."
            }
        case .groceryPlaceOrder(let provider, let items):
            let parts = items
                .filter { $0.quantity > 0 }
                .map { item -> String in
                    let qty = item.quantity.truncatingRemainder(dividingBy: 1) == 0
                        ? String(Int(item.quantity))
                        : String(item.quantity)
                    return "\(qty)× \(item.id)"
                }
            prompt = "Place the \(provider) order: \(parts.joined(separator: ", "))."
        }
        guard !isStreaming else { return }
        lastVoiceMode = .text
        startStream(prompt: prompt, addUserBubble: true)
    }

    /// Re-issue the most recent failed user message.
    func retry() {
        guard let failed = messages.last(where: { $0.role == .user && $0.status == .failed }) else { return }
        let text = failed.text
        messages.removeAll { $0.id == failed.id }
        // Also drop any assistant bubble that was failed in-flight after it.
        if let last = messages.last, last.role == .assistant, last.status == .failed {
            messages.removeLast()
        }
        startStream(prompt: text, addUserBubble: true)
    }

    /// Re-run the last user prompt without adding a new user bubble.
    /// Drops the most recent assistant message if present.
    func regenerate() {
        guard let prompt = lastUserPrompt, !isStreaming else { return }
        if let last = messages.last, last.role == .assistant {
            messages.removeLast()
        }
        startStream(prompt: prompt, addUserBubble: false)
    }

    func clearError() { error = nil }

    /// Wipe the thread back to a clean slate. Wired to the drawer's
    /// "New Chat" affordance: cancels any in-flight stream, drops all
    /// messages, clears the composer + error, and resets the latency
    /// probe so the next turn measures from a true cold start.
    func reset() {
        cancelStream()
        cancelAllCompoundStreams()
        messages = []
        input = ""
        error = nil
        isStreaming = false
        lastFirstTokenLatency = nil
        suggestionsByTurn = [:]
        selectionsByMessage = [:]
        summariesByMessage = [:]
        compoundDispatchByMessage = [:]
        searchCardsByMessage = [:]
        composedUIByMessage = [:]
        connectionRequiredByMessage = [:]
        retriedConnectionAgentIds = []
        compoundLegStatusOverrides = [:]
        compoundLegMetadata = [:]
        compoundLegDetailExpandedFor = []
    }

    /// MOBILE-CHAT-LOAD-SESSION-1 — replace the current thread with
    /// the messages from `id`. Cancels any in-flight stream, fetches
    /// the replay via the injected history fetcher, and rehydrates
    /// the message list. Subsequent `send()` calls then post against
    /// the loaded session (the orchestrator continues the same
    /// conversation server-side).
    ///
    /// On network failure the prior thread is left intact and an
    /// error is surfaced — better than silently wiping context.
    func loadSession(id: String) async {
        guard let fetcher = historyFetcher else { return }
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        cancelStream()
        cancelAllCompoundStreams()
        do {
            let resp = try await fetcher.fetchSessionMessages(sessionID: trimmed)
            sessionID = trimmed
            // Build messages first so we have the assigned UUIDs to
            // index the attach maps with. The DTO's `id` field is a
            // server-side string id; iOS's ChatMessage.id is a fresh
            // UUID — we can't use the server id as a key.
            let rehydrated: [(message: ChatMessage, dto: ReplayedMessageDTO)] =
                resp.messages.map { (Self.makeChatMessage(from: $0), $0) }
            messages = rehydrated.map(\.message)

            // Reset all attach maps + then re-fill from the rich
            // frames the server replayed. Replay reattach for
            // suggestions / selections / summaries / compound is
            // staged separately; this PR only covers the frames
            // that the server actually persists today
            // (search_cards, composed_ui, connection_required).
            input = ""
            error = nil
            isStreaming = false
            lastFirstTokenLatency = nil
            suggestionsByTurn = [:]
            selectionsByMessage = [:]
            summariesByMessage = [:]
            compoundDispatchByMessage = [:]
            searchCardsByMessage = [:]
            composedUIByMessage = [:]
            connectionRequiredByMessage = [:]
            retriedConnectionAgentIds = []
            compoundLegStatusOverrides = [:]
            compoundLegMetadata = [:]
            compoundLegDetailExpandedFor = []

            for (message, dto) in rehydrated where message.role == .assistant {
                if let sc = dto.searchCards {
                    searchCardsByMessage[message.id] = sc
                }
                if let cu = dto.composedUI {
                    composedUIByMessage[message.id] = cu
                }
                if let cr = dto.connectionRequired, cr.isRenderable {
                    connectionRequiredByMessage[message.id] = cr
                }
            }
        } catch {
            self.error = "Couldn't open that conversation."
        }
    }

    /// Test seam — appends a message without the streaming machinery.
    /// Used by MOBILE-CHAT-LOAD-SESSION-1 tests to seed prior state
    /// before exercising loadSession's preserve-on-failure path.
    func appendUserMessageForTesting(text: String) {
        messages.append(ChatMessage(role: .user, text: text, status: .sent))
    }

    /// ORCHET-IOS-PARITY-1 — wire the chat thread to a streaming
    /// voice service's transcript subjects so user + assistant
    /// bubbles render inline during a Daily WebRTC voice turn.
    ///
    /// Critical invariant: never re-dispatch the user transcript
    /// through `send()`. The voice service is running its own LLM
    /// turn; doing so would trigger Claude Sonnet in parallel and
    /// diverge the rendered chat from what the user actually heard
    /// — the bug the web parity fix already paid for.
    ///
    /// Idempotent: a re-attach replaces the existing subscriptions.
    func attachStreamingVoice(_ voice: StreamingVoiceService) {
        streamingVoiceCancellables.removeAll()
        inflightAssistantTurnKey = nil
        inflightAssistantMessageID = nil

        // Both ChatViewModel and StreamingVoiceService are @MainActor;
        // PassthroughSubject delivers synchronously on the sending
        // call stack, so no `.receive(on:)` hop is needed (and adding
        // one would defer delivery into the next runloop tick, which
        // makes the view jitter on rapid delta bursts).
        voice.userTranscript
            .sink { [weak self] msg in self?.appendVoiceUserTranscript(msg) }
            .store(in: &streamingVoiceCancellables)

        voice.assistantTranscriptDelta
            .sink { [weak self] msg in self?.applyVoiceAssistantDelta(msg) }
            .store(in: &streamingVoiceCancellables)

        voice.assistantTranscriptFinal
            .sink { [weak self] msg in self?.applyVoiceAssistantFinal(msg) }
            .store(in: &streamingVoiceCancellables)
    }

    /// Tear down the streaming voice subscriptions. Safe to call
    /// repeatedly. Called by RootView when the streaming voice
    /// session ends.
    func detachStreamingVoice() {
        streamingVoiceCancellables.removeAll()
        // Mark any orphan in-flight assistant bubble as delivered so
        // the UI doesn't render a perpetual streaming spinner.
        if let id = inflightAssistantMessageID,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].status = .delivered
        }
        inflightAssistantTurnKey = nil
        inflightAssistantMessageID = nil
    }

    private func appendVoiceUserTranscript(_ msg: VoiceUserTranscriptMessage) {
        let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text, status: .sent))
    }

    private func applyVoiceAssistantDelta(_ msg: VoiceAssistantTranscriptDeltaMessage) {
        let turnKey = msg.turn_id ?? "no-turn"
        if let id = inflightAssistantMessageID,
           inflightAssistantTurnKey == turnKey,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text += msg.text
            return
        }
        // New in-flight bubble.
        let bubble = ChatMessage(role: .assistant, text: msg.text, status: .streaming)
        messages.append(bubble)
        inflightAssistantTurnKey = turnKey
        inflightAssistantMessageID = bubble.id
    }

    private func applyVoiceAssistantFinal(_ msg: VoiceAssistantTranscriptFinalMessage) {
        let turnKey = msg.turn_id ?? "no-turn"
        if let id = inflightAssistantMessageID,
           inflightAssistantTurnKey == turnKey,
           let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text = msg.text
            messages[idx].status = .delivered
        } else {
            // Final without any deltas (e.g. dropped data-channel
            // frames) — synthesize the assistant bubble from the
            // final text alone so the user sees the response.
            messages.append(ChatMessage(role: .assistant, text: msg.text, status: .delivered))
        }
        inflightAssistantTurnKey = nil
        inflightAssistantMessageID = nil
    }

    /// Maps a server-side replayed message into the iOS ChatMessage
    /// shape. Roles outside `{user, assistant}` fall back to
    /// `.assistant` (matches the orchestrator's strict-role contract;
    /// any drift is treated as system noise rather than crashing).
    static func makeChatMessage(from replayed: ReplayedMessageDTO) -> ChatMessage {
        let role: Message.Role = (replayed.role == "user") ? .user : .assistant
        let createdAt = HistoryTimeFormatter.parseISO(replayed.created_at) ?? Date()
        let status: MessageStatus = (role == .user) ? .sent : .delivered
        return ChatMessage(
            id: UUID(),
            role: role,
            text: replayed.content,
            createdAt: createdAt,
            status: status
        )
    }

    private func cancelAllCompoundStreams() {
        for (_, task) in compoundStreamTasks {
            task.cancel()
        }
        compoundStreamTasks = [:]
    }

    /// Cancel any in-flight stream. Called when the view disappears
    /// or the user starts a new message.
    func cancelStream() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    private func startStream(prompt: String, addUserBubble: Bool) {
        cancelStream()
        isStreaming = true
        error = nil
        lastUserPrompt = prompt
        streamStartTime = Date()
        lastFirstTokenLatency = nil

        let voiceCorrelation: VoiceTelemetryCorrelation?
        if lastVoiceMode.shouldSpeak {
            voiceCorrelation = VoiceTelemetry.shared.currentTurn()?.correlation
        } else {
            voiceCorrelation = nil
        }
        if lastVoiceMode.shouldSpeak {
            tts?.beginStreaming()
        }

        if addUserBubble {
            messages.append(ChatMessage(role: .user, text: prompt, status: .sending))
        }
        let assistantID = UUID()
        messages.append(ChatMessage(id: assistantID, role: .assistant, text: "", status: .streaming))

        streamingTask = Task { [weak self] in
            await self?.runStream(
                prompt: prompt,
                assistantID: assistantID,
                addUserBubble: addUserBubble,
                voiceCorrelation: voiceCorrelation
            )
        }
    }

    private func runStream(
        prompt: String,
        assistantID: UUID,
        addUserBubble: Bool,
        voiceCorrelation: VoiceTelemetryCorrelation?
    ) async {
        var sawFirstToken = false
        do {
            for try await event in service.stream(
                message: prompt,
                sessionID: sessionID,
                voiceCorrelation: voiceCorrelation
            ) {
                if Task.isCancelled { break }
                switch event {
                case .text(let chunk):
                    if !sawFirstToken {
                        if addUserBubble { markUserSent() }
                        if let start = streamStartTime, !chunk.isEmpty {
                            lastFirstTokenLatency = Date().timeIntervalSince(start)
                        }
                    }
                    sawFirstToken = true
                    appendAssistantText(chunk, id: assistantID)
                    if lastVoiceMode.shouldSpeak {
                        tts?.appendToken(chunk)
                    }
                case .error(let detail):
                    error = detail
                    markAssistantFailed(id: assistantID)
                    if addUserBubble { markUserFailed() }
                    if lastVoiceMode.shouldSpeak {
                        tts?.cancel()
                    }
                case .done:
                    markAssistantDelivered(id: assistantID)
                    if lastVoiceMode.shouldSpeak {
                        tts?.finishStreaming()
                    }
                case .suggestions(let turnID, let items):
                    attachSuggestions(turnID: turnID, items: items, assistantID: assistantID)
                case .selection(let selection):
                    attachSelection(selection, assistantID: assistantID)
                case .summary(let summary):
                    attachSummary(summary, assistantID: assistantID)
                case .compoundDispatch(let dispatch):
                    attachCompoundDispatch(dispatch, assistantID: assistantID)
                case .searchCards(let value):
                    attachSearchCards(value, assistantID: assistantID)
                case .composedUI(let value):
                    attachComposedUI(value, assistantID: assistantID)
                case .connectionRequired(let value):
                    attachConnectionRequired(value, assistantID: assistantID)
                case .other:
                    continue
                }
            }
        } catch is CancellationError {
            // user navigated away or restarted; leave state as-is
            if lastVoiceMode.shouldSpeak { tts?.cancel() }
        } catch {
            self.error = error.localizedDescription
            markAssistantFailed(id: assistantID)
            if addUserBubble { markUserFailed() }
            if lastVoiceMode.shouldSpeak { tts?.cancel() }
        }
        isStreaming = false
        streamingTask = nil
    }

    // MARK: - Mutations (run on @MainActor by class isolation)

    private func appendAssistantText(_ chunk: String, id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].text += chunk
    }

    private func attachSuggestions(turnID: String, items: [AssistantSuggestion], assistantID: UUID) {
        suggestionsByTurn[turnID] = items
        guard let idx = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[idx].suggestionsTurnId = turnID
    }

    private func attachSelection(_ selection: InteractiveSelection, assistantID: UUID) {
        // The orchestrator emits at most one selection per kind per
        // turn (food/flight/time-slots are mutually exclusive in
        // practice today), but the storage allows a list to keep the
        // shape symmetric with web's `UIMessage.selections`. If a
        // future turn re-emits the same kind, the latest wins —
        // mirrors web's `selections.filter((x) => x.kind !== s.kind)`.
        var current = selectionsByMessage[assistantID] ?? []
        current.removeAll { existing in existing.sameKind(as: selection) }
        current.append(selection)
        selectionsByMessage[assistantID] = current
    }

    private func attachSummary(_ summary: ConfirmationSummary, assistantID: UUID) {
        // One summary per assistant turn; latest wins (the orchestrator
        // shouldn't emit a second summary on the same turn but defending
        // here keeps the view surface predictable on replay paths).
        summariesByMessage[assistantID] = summary
    }

    private func attachSearchCards(_ value: SearchCardsFrameValue, assistantID: UUID) {
        // One search_cards envelope per assistant turn. The orchestrator
        // emits exactly one after the tool-use loop exits; rare double
        // emission (e.g. on retry paths) just overwrites — latest wins.
        searchCardsByMessage[assistantID] = value
    }

    /// PARITY-1C — composed_ui frame value attach. Same lifecycle as
    /// search-cards: one envelope per assistant turn, latest wins.
    /// Action callbacks dispatched through `handleComposedAction`
    /// turn each user gesture into a follow-up text turn so the
    /// backend's flow controller can do the actual booking step.
    private func attachComposedUI(_ value: ComposedUIFrameValue, assistantID: UUID) {
        composedUIByMessage[assistantID] = value
    }

    /// PARITY-1D — inline-connect frame attach.
    private func attachConnectionRequired(
        _ value: ConnectionRequiredFrameValue,
        assistantID: UUID
    ) {
        guard value.isRenderable else { return }
        connectionRequiredByMessage[assistantID] = value
    }

    /// Called by `ConnectionRequestCardView` once the user finishes
    /// the OAuth dance in ASWebAuthenticationSession. Sends ONE
    /// follow-up turn per agent_id so the orchestrator retries the
    /// blocked tool with the new live connection. Dedup matches web.
    ///
    /// Adds a user bubble for the follow-up text so the chat thread
    /// reads coherently — matches the web flow where the user can
    /// see exactly what was auto-submitted on their behalf.
    func handleConnectionCompleted(agentId: String, displayName: String) {
        guard !retriedConnectionAgentIds.contains(agentId) else { return }
        retriedConnectionAgentIds.insert(agentId)
        // Intentionally NOT gating on `isStreaming`: a user with two
        // connection cards (e.g. Google + Lumo Rentals) who connects
        // both in quick succession deserves both follow-ups to land.
        // The orchestrator handles overlapping turns; the dedup set
        // above is the only invariant we owe.
        lastVoiceMode = .text
        startStream(
            prompt: "I've connected \(displayName). Please continue with my previous request.",
            addUserBubble: true
        )
    }

    private func attachCompoundDispatch(_ dispatch: CompoundDispatchPayload, assistantID: UUID) {
        compoundDispatchByMessage[assistantID] = dispatch
        // Seed initial overrides from the dispatch's own statuses
        // so the override layer always has a value to read for
        // every leg (simpler view-side rendering).
        let initial = Dictionary(
            uniqueKeysWithValues: dispatch.legs.map { ($0.leg_id, $0.status) }
        )
        let existing = compoundLegStatusOverrides[dispatch.compound_transaction_id] ?? [:]
        // Don't clobber later updates that may already have arrived;
        // merge the dispatch statuses in only where the override is
        // missing.
        var merged = existing
        for (leg_id, status) in initial where merged[leg_id] == nil {
            merged[leg_id] = status
        }
        compoundLegStatusOverrides[dispatch.compound_transaction_id] = merged

        // Open the live per-leg subscription if the orchestrator
        // hasn't already settled all legs. The view's settled-state
        // pulse-suppression matches web exactly.
        if !CompoundDispatchHelpers.isSettled(legs: dispatch.legs, statuses: merged),
           let stream = compoundStreamService,
           compoundStreamTasks[dispatch.compound_transaction_id] == nil {
            startCompoundStream(stream: stream, dispatch: dispatch)
        }
    }

    private func startCompoundStream(stream: CompoundStreamService, dispatch: CompoundDispatchPayload) {
        let id = dispatch.compound_transaction_id
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in stream.subscribe(compoundTransactionID: id) {
                    if Task.isCancelled { break }
                    self.applyCompoundLegStatusUpdate(update, compoundID: id)
                    // Close the subscription as soon as every leg has
                    // settled — mirrors web's `if (settled) return`
                    // gate that prevents the EventSource from
                    // reopening.
                    if let dispatch = self.compoundDispatchByMessage.values
                        .first(where: { $0.compound_transaction_id == id }),
                       CompoundDispatchHelpers.isSettled(
                        legs: dispatch.legs,
                        statuses: self.compoundLegStatusOverrides[id] ?? [:]
                       ) {
                        break
                    }
                }
            } catch {
                // Network/stream errors close the subscription
                // silently — the strip stays visible with whatever
                // statuses arrived. The user sees the last known
                // state rather than a spinner stuck forever.
            }
            self.compoundStreamTasks[id] = nil
        }
        compoundStreamTasks[id] = task
    }

    private func applyCompoundLegStatusUpdate(_ update: CompoundLegStatusUpdate, compoundID: String) {
        var overrides = compoundLegStatusOverrides[compoundID] ?? [:]
        let previous = overrides[update.leg_id]
        overrides[update.leg_id] = update.status
        compoundLegStatusOverrides[compoundID] = overrides

        // Metadata: stamp the first time we see in_flight, refresh
        // last-updated on every frame, and absorb provider_reference
        // / evidence when present. Older statuses without metadata
        // (the seed-from-dispatch path) leave the empty record alone.
        var metaForCompound = compoundLegMetadata[compoundID] ?? [:]
        var meta = metaForCompound[update.leg_id] ?? .empty
        if update.status == .in_flight && meta.firstSeenInFlightAt == nil {
            meta.firstSeenInFlightAt = Date()
        }
        if let ts = update.timestamp {
            meta.lastUpdatedAt = parseISO8601(ts) ?? meta.lastUpdatedAt
        }
        if let ref = update.provider_reference {
            meta.provider_reference = ref
        }
        if let evidence = update.evidence {
            meta.evidence = evidence
        }
        // Avoid clobbering an in_flight stamp on a benign re-emit
        // of the same status from a flaky stream.
        _ = previous
        metaForCompound[update.leg_id] = meta
        compoundLegMetadata[compoundID] = metaForCompound
    }

    private func parseISO8601(_ raw: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = parser.date(from: raw) { return d }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: raw)
    }

    /// Public helper for ChatView's render rule. True when this
    /// assistant message should currently surface its chip strip:
    /// it has a `suggestionsTurnId`, the strip is non-empty, and no
    /// user message exists *after* it in the thread (matching web's
    /// stale-suppression). Pure look-up — does not mutate state.
    func suggestions(for message: ChatMessage) -> [AssistantSuggestion] {
        guard message.role == .assistant, let turnID = message.suggestionsTurnId else { return [] }
        guard !hasUserMessageAfter(message) else { return [] }
        return suggestionsByTurn[turnID] ?? []
    }

    /// Mirror of `suggestions(for:)` for interactive-selection cards
    /// (flight offers today). Same stale-suppression rule: chips +
    /// selections both vanish once the user has moved past the
    /// assistant's offer turn.
    func selections(for message: ChatMessage) -> [InteractiveSelection] {
        guard message.role == .assistant else { return [] }
        guard !hasUserMessageAfter(message) else { return [] }
        return selectionsByMessage[message.id] ?? []
    }

    /// Confirmation summary attached to an assistant message, if any.
    /// Unlike chips and selection cards, summaries don't auto-suppress
    /// when a later user message lands — the card transitions into
    /// a `decidedLabel` state instead, mirroring the web shell's
    /// `userMessageExistsAfter(m.id)` → "Confirmed — booking…" /
    /// "Cancelled" footer copy. The view layer reads this plus
    /// `summaryDecision(for:)` to drive that transition.
    func summary(for message: ChatMessage) -> ConfirmationSummary? {
        guard message.role == .assistant else { return nil }
        return summariesByMessage[message.id]
    }

    /// Decided state for a summary's two terminal labels. `confirmed`
    /// when the next user message reads as an affirmative ("Yes, book
    /// it." / "Confirm" / etc.), `cancelled` when it cancels, nil
    /// while the user hasn't acted. Pure look-up against the message
    /// list — no separate decision cache needed because the user's
    /// own message is the source of truth.
    func summaryDecision(for message: ChatMessage) -> ConfirmationDecision? {
        guard message.role == .assistant else { return nil }
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        let later = messages.suffix(from: messages.index(after: idx))
        guard let next = later.first(where: { $0.role == .user }) else { return nil }
        let trimmed = next.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("cancel") { return .cancelled }
        return .confirmed
    }

    private func hasUserMessageAfter(_ message: ChatMessage) -> Bool {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return false }
        let later = messages.suffix(from: messages.index(after: idx))
        return later.contains(where: { $0.role == .user })
    }

    /// Compound-dispatch payload attached to an assistant message,
    /// if any. Like summaries, the strip stays visible after the
    /// user moves on — the live subscription closes when all legs
    /// reach terminal status, and the strip becomes a settled
    /// record. Mirrors web's `m.compoundDispatch` (page.tsx).
    func compoundDispatch(for message: ChatMessage) -> CompoundDispatchPayload? {
        guard message.role == .assistant else { return nil }
        return compoundDispatchByMessage[message.id]
    }

    /// Live status for a leg, reading the override layer first
    /// (most recent leg-status frame from the per-compound stream)
    /// and falling back to the dispatch's initial status. Pure
    /// look-up.
    func compoundLegStatus(compoundID: String, legID: String, fallback: CompoundLegStatus) -> CompoundLegStatus {
        compoundLegStatusOverrides[compoundID]?[legID] ?? fallback
    }

    /// Aggregate "settled" for a dispatch — convenience for the
    /// view to drive the badge + animation suppression. Same
    /// predicate web uses, applied over the override layer.
    func compoundSettled(_ dispatch: CompoundDispatchPayload) -> Bool {
        let overrides = compoundLegStatusOverrides[dispatch.compound_transaction_id] ?? [:]
        return CompoundDispatchHelpers.isSettled(legs: dispatch.legs, statuses: overrides)
    }

    /// Per-leg metadata for the detail panel (timestamps +
    /// provider_reference + evidence). Returns `.empty` when
    /// nothing has been captured for this leg, so the view layer
    /// always reads a value rather than branching on nil.
    func compoundLegMeta(compoundID: String, legID: String) -> CompoundLegMetadata {
        compoundLegMetadata[compoundID]?[legID] ?? .empty
    }

    /// True when the detail panel for `legID` should currently
    /// render (the user has tapped the row to expand).
    func isCompoundLegDetailExpanded(legID: String) -> Bool {
        compoundLegDetailExpandedFor.contains(legID)
    }

    /// Tap-to-expand handler. The CompoundLegStrip wires this
    /// into each row's onTap. Multiple legs may be expanded
    /// concurrently — toggling one doesn't collapse the others,
    /// matching the comparison-friendly UX the brief calls out.
    func toggleCompoundLegDetail(legID: String) {
        if compoundLegDetailExpandedFor.contains(legID) {
            compoundLegDetailExpandedFor.remove(legID)
        } else {
            compoundLegDetailExpandedFor.insert(legID)
        }
    }

    /// Test-only seam: prime the chat with a known message list and
    /// chip cache so tests can verify `suggestions(for:)`'s
    /// stale-suppression rule, the chip-tap → user-bubble path, and
    /// the clear-on-submit cascade without driving the real SSE
    /// stream. Production callers must not use this — the SSE path
    /// is the only legitimate way these get populated at runtime.
    func _seedForTest(
        messages: [ChatMessage],
        suggestions: [String: [AssistantSuggestion]] = [:],
        selections: [UUID: [InteractiveSelection]] = [:],
        summaries: [UUID: ConfirmationSummary] = [:],
        compoundDispatches: [UUID: CompoundDispatchPayload] = [:],
        compoundOverrides: [String: [String: CompoundLegStatus]] = [:],
        compoundMetadata: [String: [String: CompoundLegMetadata]] = [:],
        compoundExpanded: Set<String> = []
    ) {
        self.messages = messages
        self.suggestionsByTurn = suggestions
        self.selectionsByMessage = selections
        self.summariesByMessage = summaries
        self.compoundDispatchByMessage = compoundDispatches
        self.compoundLegStatusOverrides = compoundOverrides
        self.compoundLegMetadata = compoundMetadata
        self.compoundLegDetailExpandedFor = compoundExpanded
    }

    /// Test-only seam for driving a single leg-status update
    /// without spinning up the live URLSession subscription. Used
    /// by the status-transition tests.
    func _applyCompoundLegStatusForTest(_ update: CompoundLegStatusUpdate, compoundID: String) {
        applyCompoundLegStatusUpdate(update, compoundID: compoundID)
    }

    private func markAssistantDelivered(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].status = .delivered
    }

    private func markAssistantFailed(id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].status = .failed
    }

    private func markUserSent() {
        guard let idx = messages.lastIndex(where: { $0.role == .user && $0.status == .sending }) else { return }
        messages[idx].status = .sent
    }

    private func markUserFailed() {
        guard let idx = messages.lastIndex(where: { $0.role == .user && $0.status == .sending }) else { return }
        messages[idx].status = .failed
    }
}
