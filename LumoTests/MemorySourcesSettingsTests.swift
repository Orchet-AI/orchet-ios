import XCTest
@testable import Lumo

/// Tests for `MemorySourcesSettings` — the UserDefaults-backed
/// preference store driving Phase B opt-in. Critical to verify
/// because the iOS-side privacy contract hinges on these flags +
/// the per-install salt.
@MainActor
final class MemorySourcesSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MemorySourcesSettings.revokeAllLocal()
    }

    override func tearDown() {
        MemorySourcesSettings.revokeAllLocal()
        super.tearDown()
    }

    func test_defaultState_allDisabled() {
        XCTAssertFalse(MemorySourcesSettings.calendarEnabled)
        XCTAssertFalse(MemorySourcesSettings.remindersEnabled)
        XCTAssertFalse(MemorySourcesSettings.anyEnabled)
    }

    func test_toggleCalendar_persists() {
        MemorySourcesSettings.calendarEnabled = true
        XCTAssertTrue(MemorySourcesSettings.calendarEnabled)
        XCTAssertTrue(MemorySourcesSettings.anyEnabled)
        MemorySourcesSettings.calendarEnabled = false
        XCTAssertFalse(MemorySourcesSettings.calendarEnabled)
    }

    func test_toggleReminders_persists() {
        MemorySourcesSettings.remindersEnabled = true
        XCTAssertTrue(MemorySourcesSettings.remindersEnabled)
        XCTAssertTrue(MemorySourcesSettings.anyEnabled)
    }

    func test_eventIdSalt_isStableAcrossReads() {
        let first = MemorySourcesSettings.eventIdSalt
        let second = MemorySourcesSettings.eventIdSalt
        XCTAssertEqual(first, second, "salt must be stable per install — not regenerated each call")
    }

    func test_eventIdSalt_is64HexChars() {
        let salt = MemorySourcesSettings.eventIdSalt
        XCTAssertEqual(salt.count, 64, "32 bytes of SecRandomCopyBytes → 64 hex chars")
        XCTAssertTrue(
            salt.allSatisfy { c in c.isHexDigit },
            "salt should be lowercase hex"
        )
    }

    func test_revokeAllLocal_clearsTogglesAndRotatesSalt() {
        MemorySourcesSettings.calendarEnabled = true
        MemorySourcesSettings.remindersEnabled = true
        let oldSalt = MemorySourcesSettings.eventIdSalt

        MemorySourcesSettings.revokeAllLocal()

        XCTAssertFalse(MemorySourcesSettings.calendarEnabled)
        XCTAssertFalse(MemorySourcesSettings.remindersEnabled)
        let newSalt = MemorySourcesSettings.eventIdSalt
        XCTAssertNotEqual(
            oldSalt, newSalt,
            "salt must rotate on revoke so any future re-enable can't be correlated to prior hashes"
        )
    }

    func test_anyEnabled_isTrueWhenEitherIsOn() {
        XCTAssertFalse(MemorySourcesSettings.anyEnabled)
        MemorySourcesSettings.calendarEnabled = true
        XCTAssertTrue(MemorySourcesSettings.anyEnabled)
        MemorySourcesSettings.calendarEnabled = false
        MemorySourcesSettings.remindersEnabled = true
        XCTAssertTrue(MemorySourcesSettings.anyEnabled)
    }
}
