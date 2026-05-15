import XCTest
@testable import Lumo

/// ORCHET-IOS-MEMORY-LEARNING Phase A — tests for the iOS half of
/// the behavioural memory channel.
///
/// Network is short-circuited: we don't configure `userIDProvider` /
/// `accessTokenProvider`, so flushes return early after the auth
/// check. That lets us validate the buffer + persistence + dedupe
/// invariants without a real Supabase round-trip.
@MainActor
final class BehaviourSignalServiceTests: XCTestCase {

    private func makeService(directory: URL) -> BehaviourSignalService {
        BehaviourSignalService(
            session: .shared,
            gatewayBaseURL: URL(string: "http://localhost:0")!,
            userIDProvider: { nil },           // auth not set → flush no-ops
            accessTokenProvider: { nil },
            bufferDirectory: directory
        )
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumo-bsig-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - record() + flush triggers

    func test_record_appendsToBuffer() async {
        let dir = makeTempDirectory()
        let svc = makeService(directory: dir)
        svc.clearBufferForTesting()

        svc.record(kind: .appOpen)
        try? await Task.sleep(nanoseconds: 50_000_000)  // let the Task hop land

        XCTAssertEqual(svc.pendingCountForTesting, 1)
    }

    func test_record_persistsToDiskAcrossInstances() async {
        let dir = makeTempDirectory()
        let first = makeService(directory: dir)
        first.clearBufferForTesting()
        first.record(kind: .chatTurnSent, attributes: ["mode": .string("text")])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(first.pendingCountForTesting, 1)

        // Build a new instance pointing at the same directory — it
        // should load the buffered envelope from disk.
        let second = makeService(directory: dir)
        XCTAssertEqual(
            second.pendingCountForTesting, 1,
            "second instance must reload the persisted buffer from disk"
        )
    }

    // MARK: - flushNow / unauthenticated path

    func test_flushNow_withNoAuth_doesNotClearBuffer() async {
        let dir = makeTempDirectory()
        let svc = makeService(directory: dir)
        svc.clearBufferForTesting()
        for _ in 0..<3 { svc.record(kind: .appOpen) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(svc.pendingCountForTesting, 3)

        svc.flushNow()
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            svc.pendingCountForTesting,
            3,
            "buffer must survive a flush attempt that hits the auth-not-ready short-circuit"
        )
    }

    // MARK: - clearBufferForTesting

    func test_clearBuffer_persistsEmptyToDisk() async {
        let dir = makeTempDirectory()
        let first = makeService(directory: dir)
        first.record(kind: .appOpen)
        first.record(kind: .appBackground)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(first.pendingCountForTesting, 0)

        first.clearBufferForTesting()
        XCTAssertEqual(first.pendingCountForTesting, 0)

        // Reload to confirm disk has been cleared.
        let second = makeService(directory: dir)
        XCTAssertEqual(second.pendingCountForTesting, 0)
    }

    // MARK: - AttributeValue Codable round-trip

    func test_attributeValue_codable_roundTrips_eachVariant() throws {
        let cases: [BehaviourSignalService.AttributeValue] = [
            .string("hello"),
            .bool(true),
            .bool(false),
            .int(42),
            .double(3.14),
        ]
        for value in cases {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(
                BehaviourSignalService.AttributeValue.self,
                from: encoded
            )
            XCTAssertEqual(decoded, value, "round-trip failed for \(value)")
        }
    }

    // MARK: - Kind raw-value contract (wire compatibility with backend)

    func test_kind_rawValues_matchBackendEnum() {
        // The backend `user_signals.kind` CHECK constraint
        // enumerates exactly these 10 values. If iOS drifts, signals
        // will 4xx out. Locked in.
        XCTAssertEqual(BehaviourSignalService.Kind.appOpen.rawValue, "app_open")
        XCTAssertEqual(BehaviourSignalService.Kind.appBackground.rawValue, "app_background")
        XCTAssertEqual(BehaviourSignalService.Kind.voiceSessionStart.rawValue, "voice_session_start")
        XCTAssertEqual(BehaviourSignalService.Kind.voiceSessionEnd.rawValue, "voice_session_end")
        XCTAssertEqual(BehaviourSignalService.Kind.chatTurnSent.rawValue, "chat_turn_sent")
        XCTAssertEqual(BehaviourSignalService.Kind.featureUsed.rawValue, "feature_used")
        XCTAssertEqual(BehaviourSignalService.Kind.agentInstallCompleted.rawValue, "agent_install_completed")
        XCTAssertEqual(BehaviourSignalService.Kind.agentUninstall.rawValue, "agent_uninstall")
        XCTAssertEqual(BehaviourSignalService.Kind.screenView.rawValue, "screen_view")
        XCTAssertEqual(BehaviourSignalService.Kind.marketplaceBrowse.rawValue, "marketplace_browse")
    }
}
