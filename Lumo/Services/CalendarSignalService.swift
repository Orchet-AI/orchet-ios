import CryptoKit
import EventKit
import Foundation
import UIKit

/// CalendarSignalService — Phase B of ORCHET-IOS-MEMORY-LEARNING.
///
/// Reads upcoming EventKit events + recent reminders, hashes each
/// event's identifier with a per-install salt (backend never sees
/// the raw EventKit id), and posts batches to
/// `POST /memory/signals` with `kind: "calendar_event"`. The
/// backend's fact extractor surfaces upcoming events and recurring
/// patterns as facts the voice/chat agent sees on the next turn.
///
/// **Triggers**
/// - Initial sync on enable: pull next 14 days of events + open
///   reminders.
/// - Foreground re-sync: every time the app comes to foreground,
///   if Memory Sources → Calendar is enabled.
/// - EKEventStoreChanged notification: re-sync the affected calendars.
///
/// **Privacy contract (ADR-014)**
/// - In-app opt-in toggle (`MemorySourcesSettings.calendarEnabled`)
///   on top of the OS EventKit permission. Service refuses to sync
///   when either is off.
/// - Event identifiers are SHA-256 hashed with a per-install salt
///   before they leave the device. Backend has no way to correlate
///   across re-installs or back to a raw EventKit id.
/// - Content (title, location, time) is bounded by schema CHECK on
///   the backend, but iOS still clamps client-side as defense.
/// - "Forget" deletes local salt + posts to
///   `/memory/calendar/forget`.
@MainActor
final class CalendarSignalService {
    static let shared = CalendarSignalService()

    private let eventStore = EKEventStore()
    private var configured = false
    private var session: URLSession = .shared
    private var gatewayBaseURL: URL?
    private var userIDProvider: () -> String? = { nil }
    private var accessTokenProvider: () -> String? = { nil }
    private var eventStoreObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var syncTask: Task<Void, Never>?

    /// Calendars/reminders span 14 days ahead — matches the backend
    /// `UPCOMING_EVENT_HORIZON_DAYS`. Events further out aren't
    /// fact-worthy yet; the next sync picks them up.
    static let lookaheadDays = 14
    static let batchSize = 100
    /// Title clamp on-device. Schema CHECK is 200; we cap at 200 here
    /// so the boundary holds even if the server-side check changes.
    static let titleMaxLength = 200
    static let locationMaxLength = 200

    init() {}

    /// Inject auth/URL plumbing from `LumoApp` boot.
    func configure(
        gatewayBaseURL: URL?,
        userIDProvider: @escaping () -> String?,
        accessTokenProvider: @escaping () -> String?,
        session: URLSession = .shared
    ) {
        self.gatewayBaseURL = gatewayBaseURL
        self.userIDProvider = userIDProvider
        self.accessTokenProvider = accessTokenProvider
        self.session = session
        self.configured = true
        installObserversIfNeeded()
    }

    /// Public entry — called from Settings on toggle, on boot if
    /// already enabled, and on EKEventStoreChanged. Idempotent; the
    /// in-flight task is replaced rather than enqueued.
    func syncNow() {
        guard MemorySourcesSettings.calendarEnabled,
              configured,
              EKEventStore.authorizationStatus(for: .event) == .fullAccess
        else { return }

        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.runSync()
        }
    }

    /// Request OS permission + flip the in-app toggle to enabled on
    /// success. Mirrors the existing voice-permission shape — true
    /// = "user is now opted in", false = "user denied or system
    /// blocked".
    func requestPermissionAndEnable() async -> Bool {
        let granted: Bool
        if #available(iOS 17.0, *) {
            granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .event) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
        }
        guard granted else {
            MemorySourcesSettings.calendarEnabled = false
            return false
        }
        MemorySourcesSettings.calendarEnabled = true
        syncNow()
        return true
    }

    /// Locally clears the toggle + posts to `/memory/calendar/forget`
    /// so backend signal rows + extractor facts get wiped. Local
    /// salt rotates so any future re-enable can't be correlated
    /// against the prior signal set.
    func forgetEverything() async {
        MemorySourcesSettings.calendarEnabled = false
        MemorySourcesSettings.revokeAllLocal()
        guard let url = forgetURL(),
              let token = accessTokenProvider(),
              !token.isEmpty,
              let userId = userIDProvider(),
              !userId.isEmpty
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userId, forHTTPHeaderField: "x-orchet-user-id")
        _ = try? await session.data(for: req)
    }

    // MARK: - Sync pipeline

    private func runSync() async {
        guard let url = signalsURL(),
              let token = accessTokenProvider(),
              !token.isEmpty,
              let userId = userIDProvider(),
              !userId.isEmpty
        else { return }

        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: Self.lookaheadDays, to: now)
            ?? now.addingTimeInterval(TimeInterval(Self.lookaheadDays) * 86_400)

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: horizon,
            calendars: calendars.isEmpty ? nil : calendars,
        )
        let events = eventStore.events(matching: predicate)
        let envelopes = events
            .compactMap { encodeEnvelope($0) }
            .prefix(Self.batchSize)
            .map { $0 }
        guard !envelopes.isEmpty else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(userId, forHTTPHeaderField: "x-orchet-user-id")
        let body: [String: Any] = ["signals": envelopes]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
    }

    // MARK: - Encoding

    private func encodeEnvelope(_ event: EKEvent) -> [String: Any]? {
        guard let id = event.eventIdentifier else { return nil }
        let title = clamp(event.title ?? "", max: Self.titleMaxLength)
        guard !title.isEmpty else { return nil }
        guard let starts = event.startDate else { return nil }

        var envelope: [String: Any] = [
            "kind": "calendar_event",
            "event_id_hash": hashEventId(id),
            "title": title,
            "occurrence_starts_at": isoFormatter.string(from: starts),
            "is_recurring": event.hasRecurrenceRules,
            "attendees_count": event.attendees?.count ?? 0,
        ]
        if let ends = event.endDate {
            envelope["occurrence_ends_at"] = isoFormatter.string(from: ends)
        }
        if let location = event.location, !location.isEmpty {
            envelope["location"] = clamp(location, max: Self.locationMaxLength)
        }
        if let label = event.calendar?.title {
            envelope["calendar_label"] = clamp(label, max: 120)
        }
        return envelope
    }

    /// SHA-256(salt + ":" + eventIdentifier). The colon separator
    /// prevents a salt collision attack (different salt + id pairs
    /// that concatenate to the same string).
    private func hashEventId(_ raw: String) -> String {
        let salt = MemorySourcesSettings.eventIdSalt
        let combined = "\(salt):\(raw)"
        let digest = SHA256.hash(data: Data(combined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func clamp(_ s: String, max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(max))
    }

    // MARK: - URLs

    private func signalsURL() -> URL? {
        gatewayBaseURL?.appendingPathComponent("memory/signals")
    }

    private func forgetURL() -> URL? {
        gatewayBaseURL?.appendingPathComponent("memory/calendar/forget")
    }

    // MARK: - Observers

    private func installObserversIfNeeded() {
        if eventStoreObserver == nil {
            eventStoreObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged,
                object: eventStore,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            }
        }
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncNow() }
            }
        }
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
