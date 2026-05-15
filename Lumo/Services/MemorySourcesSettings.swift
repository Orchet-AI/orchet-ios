import Foundation

/// Persisted user preferences for Memory Sources (Phase B of
/// ORCHET-IOS-MEMORY-LEARNING).
///
/// Each source is independently opt-in. The OS permission grant is
/// a prerequisite (EventKit's `requestFullAccessToEvents`); this
/// toggle is the layered in-app gate. We need both: the user might
/// have granted Calendar access to another app on the device and
/// not realize Orchet would consume it, so we keep the in-app
/// toggle as a second consent surface.
///
/// All accessors are static + `UserDefaults`-backed so callers can
/// hit them from any context (Settings view, CalendarSignalService,
/// the boot-time wiring in LumoApp).
enum MemorySourcesSettings {
    private static let calendarEnabledKey = "lumo.memory.sources.calendar.enabled"
    private static let remindersEnabledKey = "lumo.memory.sources.reminders.enabled"
    /// SHA-256 input salt for hashing EventKit event identifiers
    /// before they leave the device. Generated once per install,
    /// persisted; new install = fresh salt = backend can't correlate
    /// across re-installs.
    private static let eventIdSaltKey = "lumo.memory.sources.event_id_salt"

    static var calendarEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: calendarEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: calendarEnabledKey) }
    }

    static var remindersEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: remindersEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: remindersEnabledKey) }
    }

    /// Stable per-install salt for hashing EventKit ids. Regenerates
    /// lazily on first access. Cleared on `revokeAllMemorySources`
    /// so a re-enable mints a fresh salt and the backend's old
    /// hashes become uncorrelatable.
    static var eventIdSalt: String {
        if let cached = UserDefaults.standard.string(forKey: eventIdSaltKey),
           !cached.isEmpty {
            return cached
        }
        let fresh = Self.generateSalt()
        UserDefaults.standard.set(fresh, forKey: eventIdSaltKey)
        return fresh
    }

    /// True if any source is currently enabled. Used by the boot
    /// wiring to decide whether to spin up `CalendarSignalService`.
    static var anyEnabled: Bool {
        calendarEnabled || remindersEnabled
    }

    /// Clear every Memory Source toggle + rotate the per-install
    /// salt. Backs the "Disable everything" path. Server-side
    /// signal rows + derived facts are cleared via the
    /// `/memory/calendar/forget` route; this only wipes local
    /// preference state.
    static func revokeAllLocal() {
        UserDefaults.standard.removeObject(forKey: calendarEnabledKey)
        UserDefaults.standard.removeObject(forKey: remindersEnabledKey)
        UserDefaults.standard.removeObject(forKey: eventIdSaltKey)
    }

    private static func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed; SoR for salt is the OS RNG")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
