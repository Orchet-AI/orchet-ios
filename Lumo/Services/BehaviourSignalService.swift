import Foundation
import UIKit

/// ORCHET-IOS-MEMORY-LEARNING Phase A — captures iOS-side behavioural
/// signals (app opens, voice sessions, chat turns, agent installs,
/// screen views) and batch-posts them to `POST /memory/signals`.
///
/// The backend fact extractor cron walks recently-inserted
/// `user_signals` rows, summarizes cohorts, and writes fact-worthy
/// patterns to `user_facts` with `source = 'behavioral'`. Means a
/// user who opens voice mode every weekday at 6pm gets the fact
/// *"Active in voice mode on weekday evenings"* without ever
/// saying it.
///
/// Design contract (ADR-014):
/// - **No content.** Event names + structured enum-like attributes
///   only. Attribute keys are whitelisted per kind; values are
///   strings / bools / numbers (route-side schema enforces).
/// - **Idempotent.** Every envelope carries a client-generated
///   UUID. Retried flushes after a network blip don't double-count.
/// - **Fail-open.** A network outage cannot crash the app, drop
///   messages silently, or block any user action. Buffer to disk,
///   retry with exponential backoff, drop after 24 hours.
///
/// Flush triggers:
///   - In-memory queue length ≥ 50
///   - App background scene phase
///   - Periodic timer every 5 min while foregrounded
///
/// Singleton because there's exactly one buffer to coordinate.
@MainActor
final class BehaviourSignalService: ObservableObject {
    /// Discriminator for the kind of signal recorded. The set MUST
    /// match the backend `user_signals.kind` CHECK constraint and
    /// the route-layer whitelist — they are the single source of
    /// truth for what gets ingested. Adding a value requires
    /// migration + route enum update in lockstep (ADR-014).
    enum Kind: String, Codable {
        case appOpen = "app_open"
        case appBackground = "app_background"
        case voiceSessionStart = "voice_session_start"
        case voiceSessionEnd = "voice_session_end"
        case chatTurnSent = "chat_turn_sent"
        case featureUsed = "feature_used"
        case agentInstallCompleted = "agent_install_completed"
        case agentUninstall = "agent_uninstall"
        case screenView = "screen_view"
        case marketplaceBrowse = "marketplace_browse"
    }

    static let shared = BehaviourSignalService()

    private struct Envelope: Codable {
        let client_event_id: String
        let kind: String
        let attributes: [String: AttributeValue]
        let occurred_at: String
    }

    /// Mirrors the backend's accepted attribute value types
    /// (string / number / bool). Encodes/decodes through a
    /// untagged union so the JSON wire shape stays compact.
    enum AttributeValue: Codable, Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)
        case double(Double)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v); return }
            if let v = try? c.decode(Int.self) { self = .int(v); return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            self = .string(try c.decode(String.self))
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            }
        }
    }

    /// Item on the buffer — envelope + when we first tried to send.
    /// The `firstAttemptAt` is what drives the 24-hour drop policy.
    private struct BufferedItem: Codable {
        let envelope: Envelope
        let firstAttemptAt: Date
    }

    private let session: URLSession
    private let gatewayBaseURL: URL?
    private let userIDProvider: () -> String?
    private let accessTokenProvider: () -> String?

    /// Backing buffer. Loaded from disk on init; persisted on every
    /// mutation so a crash mid-flush doesn't lose pending signals.
    private var buffer: [BufferedItem] = []
    private var flushTask: Task<Void, Never>?
    private var periodicTimerTask: Task<Void, Never>?
    private let bufferFileURL: URL

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // Tuning knobs surfaced for tests + future ops without forking
    // the class. Defaults match the brief.
    var maxBatchSize: Int = 50
    var maxBufferAge: TimeInterval = 24 * 60 * 60  // 24h drop
    var periodicFlushInterval: TimeInterval = 5 * 60  // 5 min
    var retryBackoffSeconds: [TimeInterval] = [2, 5, 15, 30]

    init(
        session: URLSession = .shared,
        gatewayBaseURL: URL? = nil,
        userIDProvider: @escaping () -> String? = { nil },
        accessTokenProvider: @escaping () -> String? = { nil },
        bufferDirectory: URL? = nil
    ) {
        self.session = session
        self.gatewayBaseURL = gatewayBaseURL
        self.userIDProvider = userIDProvider
        self.accessTokenProvider = accessTokenProvider
        let dir = bufferDirectory ?? Self.defaultBufferDirectory()
        self.bufferFileURL = dir.appendingPathComponent("lumo-behaviour-buffer.json")
        loadBufferFromDisk()
        installScenePhaseObservers()
        startPeriodicTimer()
    }

    /// Inject dependencies after construction. The shared singleton
    /// is built before AppConfig has loaded; this swaps in real
    /// auth/network providers from `LumoApp` boot.
    func configure(
        gatewayBaseURL: URL?,
        userIDProvider: @escaping () -> String?,
        accessTokenProvider: @escaping () -> String?
    ) {
        _gatewayBaseURL = gatewayBaseURL
        _userIDProvider = userIDProvider
        _accessTokenProvider = accessTokenProvider
    }

    // The init-time fields above are `let`-y to keep tests
    // deterministic; the configure() path uses mutable shadows so
    // the shared singleton can be reconfigured at boot without
    // rebuilding the whole class.
    private var _gatewayBaseURL: URL?
    private var _userIDProvider: (() -> String?)?
    private var _accessTokenProvider: (() -> String?)?

    /// Record a signal. Non-blocking; persists to disk + schedules
    /// a flush. Safe to call from any UI surface — the singleton
    /// hops to MainActor internally.
    nonisolated func record(
        kind: Kind,
        attributes: [String: AttributeValue] = [:]
    ) {
        let envelope = Envelope(
            client_event_id: UUID().uuidString.lowercased(),
            kind: kind.rawValue,
            attributes: attributes,
            occurred_at: ""
        )
        Task { @MainActor [weak self] in
            self?.append(envelope: envelope)
        }
    }

    private func append(envelope: Envelope) {
        // Stamp occurred_at at append time (not record(...) call
        // time) because the Task hop is async. Difference is sub-
        // millisecond in practice.
        let stamped = Envelope(
            client_event_id: envelope.client_event_id,
            kind: envelope.kind,
            attributes: envelope.attributes,
            occurred_at: isoFormatter.string(from: Date())
        )
        buffer.append(BufferedItem(envelope: stamped, firstAttemptAt: Date()))
        persistBuffer()
        if buffer.count >= maxBatchSize {
            scheduleFlush()
        }
    }

    /// Force a flush — used at backgrounding + by tests. Idempotent.
    func flushNow() {
        scheduleFlush()
    }

    // MARK: - Flush pipeline

    private func scheduleFlush() {
        // Coalesce: if a flush is already in flight, don't fire
        // another. The in-flight task will pick up whatever the
        // buffer holds when it sends.
        if flushTask != nil { return }
        flushTask = Task { [weak self] in
            await self?.runFlush()
            await MainActor.run { self?.flushTask = nil }
        }
    }

    private func runFlush() async {
        // Drop items older than maxBufferAge BEFORE attempting send.
        // A signal nobody can deliver in 24h is stale; carrying it
        // forever bloats the buffer.
        prune()
        guard !buffer.isEmpty else { return }
        guard let url = postURL() else { return }
        guard let token = effectiveAccessToken(), !token.isEmpty else { return }
        guard let userId = effectiveUserId(), !userId.isEmpty else { return }

        // Take a snapshot. If POST succeeds, drop those envelopes
        // from the buffer; if it fails, leave them for the next
        // try. Concurrent appends to `buffer` during the await are
        // safe because the snapshot is value-typed.
        let batch = Array(buffer.prefix(maxBatchSize))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userId, forHTTPHeaderField: "x-orchet-user-id")

        let body = ["signals": batch.map(\.envelope)]
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            // Encoding shouldn't fail; if it does, drop the batch —
            // re-trying with the same payload won't help and would
            // wedge the buffer forever.
            removeSentEnvelopes(batch)
            return
        }

        let (status, _): (Int, Data) = await sendWithRetry(request: request)
        if status == 200 {
            removeSentEnvelopes(batch)
        } else if status == 401 || status == 403 {
            // Auth not ready. Keep buffer; next flush after sign-in
            // picks it up. Don't burn retry budget on 401.
            return
        }
        // 4xx/5xx other than auth: leave for next periodic flush.
    }

    /// HTTP send with exponential-ish backoff. Returns the final
    /// status + body. Stops after retryBackoffSeconds is exhausted.
    private func sendWithRetry(request: URLRequest) async -> (Int, Data) {
        var lastStatus = 0
        var lastBody = Data()
        for delay in [0] + retryBackoffSeconds {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastStatus = code
                lastBody = data
                if code == 200 { return (200, data) }
                if code == 401 || code == 403 { return (code, data) }
                if (400..<500).contains(code) { return (code, data) }
                // 5xx falls through and retries.
            } catch {
                // network error — retry
                continue
            }
        }
        return (lastStatus, lastBody)
    }

    private func removeSentEnvelopes(_ batch: [BufferedItem]) {
        let sentIds = Set(batch.map { $0.envelope.client_event_id })
        buffer.removeAll { sentIds.contains($0.envelope.client_event_id) }
        persistBuffer()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxBufferAge)
        let before = buffer.count
        buffer.removeAll { $0.firstAttemptAt < cutoff }
        if buffer.count != before { persistBuffer() }
    }

    private func postURL() -> URL? {
        let base = _gatewayBaseURL ?? gatewayBaseURL
        return base?.appendingPathComponent("memory/signals")
    }

    private func effectiveAccessToken() -> String? {
        (_accessTokenProvider ?? accessTokenProvider)()
    }

    private func effectiveUserId() -> String? {
        (_userIDProvider ?? userIDProvider)()
    }

    // MARK: - Persistence

    private static func defaultBufferDirectory() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persistBuffer() {
        do {
            let data = try JSONEncoder().encode(buffer)
            try data.write(to: bufferFileURL, options: [.atomic])
        } catch {
            // Disk full / sandboxed denial — drop the persistence
            // attempt. Buffer stays in memory; will be lost on app
            // restart but won't crash.
        }
    }

    private func loadBufferFromDisk() {
        guard let data = try? Data(contentsOf: bufferFileURL) else { return }
        if let decoded = try? JSONDecoder().decode([BufferedItem].self, from: data) {
            buffer = decoded
        }
    }

    // MARK: - Scene observers

    private func installScenePhaseObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.record(kind: .appBackground)
            Task { @MainActor in self.flushNow() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.flushNow() }
        }
    }

    private func startPeriodicTimer() {
        periodicTimerTask?.cancel()
        periodicTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(
                    nanoseconds: UInt64(self.periodicFlushInterval * 1_000_000_000)
                )
                if Task.isCancelled { return }
                await MainActor.run { self.flushNow() }
            }
        }
    }

    deinit {
        flushTask?.cancel()
        periodicTimerTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Test seam

    /// Visible for tests. Returns the count of envelopes currently
    /// buffered (pending flush).
    var pendingCountForTesting: Int { buffer.count }

    /// Visible for tests. Drains the buffer without flushing.
    func clearBufferForTesting() {
        buffer.removeAll()
        persistBuffer()
    }
}
