import XCTest
@testable import Lumo

/// P2H-6 contract parity tests for the memory + history-sessions
/// surface of DrawerScreensClient. Pins request method, path, body
/// shape, and headers across both the legacy-fallback (gatewayBaseURL
/// nil → apps/web /api/* BFF) and gateway-direct (gatewayBaseURL set
/// → canonical /memory/*, /history/sessions/.../messages) modes.
///
/// Pre-existing tests in this repo did not cover DrawerScreensClient's
/// HTTP layer; the FakeDrawerScreensFetcher stub bypasses URLSession
/// entirely. These tests use a URLProtocol mock that records and
/// matches by exact path + method, which is the same pattern
/// PaymentServiceTests uses.
final class DrawerScreensClientMemoryTests: XCTestCase {

    // MARK: - GET /memory

    func test_p2h6_fetchMemory_legacyFallback() async throws {
        let json = #"""
        {"profile":null,"facts":[],"patterns":[]}
        """#
        let session = mockSession([.init(method: "GET", path: "/api/memory", status: 200, body: json)])
        let client = makeClient(session: session, gatewayBaseURL: nil)
        let response = try await client.fetchMemory()
        XCTAssertNil(response.profile)
        XCTAssertEqual(response.facts.count, 0)
        XCTAssertEqual(response.patterns.count, 0)
        let recorded = DSMemoryURLProtocolMock.recorded.first(where: { $0.url?.path == "/api/memory" })
        XCTAssertEqual(recorded?.httpMethod, "GET")
    }

    func test_p2h6_fetchMemory_gatewayDirect() async throws {
        let json = #"""
        {"profile":null,"facts":[],"patterns":[]}
        """#
        let session = mockSession([.init(method: "GET", path: "/memory", status: 200, body: json)])
        let client = makeClient(
            session: session,
            gatewayBaseURL: URL(string: "http://localhost:9999")!
        )
        _ = try await client.fetchMemory()
        guard let recorded = DSMemoryURLProtocolMock.recorded.first(where: { $0.url?.path == "/memory" }) else {
            return XCTFail("gateway-direct path /memory not hit")
        }
        XCTAssertEqual(recorded.httpMethod, "GET")
    }

    // MARK: - PATCH /memory/profile

    func test_p2h6_updateMemoryProfile_pinsBodyShape_legacyFallback() async throws {
        let json = #"""
        {"profile":{"display_name":"Kalas","timezone":null,"preferred_language":null,"home_address":null,"work_address":null,"dietary_flags":[],"allergies":[],"preferred_airline_class":null,"preferred_airline_seat":null,"preferred_hotel_chains":[],"budget_tier":null,"preferred_payment_hint":null}}
        """#
        let session = mockSession([.init(
            method: "PATCH",
            path: "/api/memory/profile",
            status: 200,
            body: json
        )])
        let client = makeClient(session: session, gatewayBaseURL: nil)
        _ = try await client.updateMemoryProfile(
            MemoryProfilePatchDTO(display_name: "Kalas")
        )
        guard let request = DSMemoryURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/api/memory/profile" && $0.httpMethod == "PATCH"
        }) else {
            return XCTFail("PATCH /api/memory/profile not hit")
        }
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        guard let bodyData = request.bodyData,
              let parsed = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            return XCTFail("body not parseable JSON")
        }
        // The PATCH body is the patch object itself; updateMemoryProfile
        // sends the DTO directly — keys match what svc-orchestrator's
        // patchMemoryProfileHandler forwards into upsertProfile.
        XCTAssertEqual(parsed["display_name"] as? String, "Kalas")
    }

    func test_p2h6_updateMemoryProfile_gatewayDirect() async throws {
        let json = #"""
        {"profile":{"display_name":"Kalas","timezone":null,"preferred_language":null,"home_address":null,"work_address":null,"dietary_flags":[],"allergies":[],"preferred_airline_class":null,"preferred_airline_seat":null,"preferred_hotel_chains":[],"budget_tier":null,"preferred_payment_hint":null}}
        """#
        let session = mockSession([.init(
            method: "PATCH",
            path: "/memory/profile",
            status: 200,
            body: json
        )])
        let client = makeClient(
            session: session,
            gatewayBaseURL: URL(string: "http://localhost:9999")!
        )
        _ = try await client.updateMemoryProfile(
            MemoryProfilePatchDTO(display_name: "Kalas")
        )
        XCTAssertNotNil(DSMemoryURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/memory/profile" && $0.httpMethod == "PATCH"
        }))
    }

    // MARK: - DELETE /memory/facts/:fact_id

    func test_p2h6_forgetMemoryFact_pinsMethodAndPath_legacyFallback() async throws {
        let session = mockSession([.init(
            method: "DELETE",
            path: "/api/memory/facts/fact-abc",
            status: 200,
            body: #"{"ok":true}"#
        )])
        let client = makeClient(session: session, gatewayBaseURL: nil)
        try await client.forgetMemoryFact(id: "fact-abc")
        XCTAssertNotNil(DSMemoryURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/api/memory/facts/fact-abc" && $0.httpMethod == "DELETE"
        }))
    }

    func test_p2h6_forgetMemoryFact_gatewayDirect() async throws {
        let session = mockSession([.init(
            method: "DELETE",
            path: "/memory/facts/fact-abc",
            status: 200,
            body: #"{"ok":true}"#
        )])
        let client = makeClient(
            session: session,
            gatewayBaseURL: URL(string: "http://localhost:9999")!
        )
        try await client.forgetMemoryFact(id: "fact-abc")
        XCTAssertNotNil(DSMemoryURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/memory/facts/fact-abc" && $0.httpMethod == "DELETE"
        }))
    }

    func test_p2h6_forgetMemoryFact_emptyId_throws() async {
        let client = makeClient(session: .shared, gatewayBaseURL: nil)
        do {
            try await client.forgetMemoryFact(id: "")
            XCTFail("expected throw on empty id")
        } catch {
            // expected
        }
    }

    // MARK: - GET /history/sessions/:id/messages

    func test_p2h6_fetchSessionMessages_parsing_legacyFallback() async throws {
        let json = #"""
        {"session_id":"sess-1","messages":[{"id":"m1","role":"user","content":"hi","created_at":"2026-04-30T12:00:00.000Z"}]}
        """#
        let session = mockSession([.init(
            method: "GET",
            path: "/api/history/sessions/sess-1/messages",
            status: 200,
            body: json
        )])
        let client = makeClient(session: session, gatewayBaseURL: nil)
        let response = try await client.fetchSessionMessages(sessionID: "sess-1")
        XCTAssertEqual(response.session_id, "sess-1")
        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages.first?.id, "m1")
    }

    func test_p2h6_fetchSessionMessages_gatewayDirect() async throws {
        let json = #"""
        {"session_id":"sess-1","messages":[]}
        """#
        let session = mockSession([.init(
            method: "GET",
            path: "/history/sessions/sess-1/messages",
            status: 200,
            body: json
        )])
        let client = makeClient(
            session: session,
            gatewayBaseURL: URL(string: "http://localhost:9999")!
        )
        _ = try await client.fetchSessionMessages(sessionID: "sess-1")
        XCTAssertNotNil(DSMemoryURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/history/sessions/sess-1/messages"
        }))
    }

    // MARK: - GET /api/history (BLOCKED — list endpoint missing on orchestrator)

    func test_p2h6_fetchHistory_listStillUsesLegacyPath_untilP2J() async throws {
        // Until P2J-history-list lands, fetchHistory must continue to
        // hit the apps/web BFF directly, NOT the gateway. Verify the
        // request URL has the legacy /api/history prefix even when
        // gatewayBaseURL is set.
        let json = #"""
        {"sessions":[],"trips":[]}
        """#
        let session = mockSession([.init(
            method: "GET",
            path: "/api/history",
            status: 200,
            body: json
        )])
        let client = makeClient(
            session: session,
            gatewayBaseURL: URL(string: "http://localhost:9999")!
        )
        _ = try await client.fetchHistory()
        XCTAssertNotNil(
            DSMemoryURLProtocolMock.recorded.first(where: {
                $0.url?.path == "/api/history"
            }),
            "fetchHistory should still hit /api/history; flip to /history only after P2J-history-list lands"
        )
    }

    // MARK: - Helpers

    private func makeClient(session: URLSession, gatewayBaseURL: URL?) -> DrawerScreensClient {
        DrawerScreensClient(
            baseURL: URL(string: "http://localhost:9999")!,
            gatewayBaseURL: gatewayBaseURL,
            userIDProvider: { "test-user" },
            accessTokenProvider: { "test-bearer" },
            session: session
        )
    }

    private func mockSession(_ responses: [DSMemoryURLProtocolMock.Stub]) -> URLSession {
        DSMemoryURLProtocolMock.queue = responses
        DSMemoryURLProtocolMock.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DSMemoryURLProtocolMock.self]
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol mock (scoped to this test file)

final class DSMemoryURLProtocolMock: URLProtocol {
    struct Stub {
        let method: String
        let path: String
        let status: Int
        let body: String
    }
    struct Recorded {
        let url: URL?
        let httpMethod: String?
        let bodyData: Data?
        let headers: [String: String]
    }

    static var queue: [Stub] = []
    static var recorded: [Recorded] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData: Data? = {
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let n = stream.read(buffer, maxLength: 1024)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                return data
            }
            return request.httpBody
        }()
        let headers = request.allHTTPHeaderFields ?? [:]
        Self.recorded.append(.init(
            url: request.url,
            httpMethod: request.httpMethod,
            bodyData: bodyData,
            headers: headers
        ))

        guard let stub = Self.matchAndConsume(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func matchAndConsume(for request: URLRequest) -> Stub? {
        guard let path = request.url?.path else { return nil }
        if let idx = queue.firstIndex(where: { $0.method == request.httpMethod && $0.path == path }) {
            return queue.remove(at: idx)
        }
        return nil
    }
}
