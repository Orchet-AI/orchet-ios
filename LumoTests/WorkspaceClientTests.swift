import XCTest
@testable import Lumo

/// HTTP contract tests for WorkspaceClient. Uses a URLProtocol stub
/// so the test exercises the real request-formation + decoder path
/// without hitting the network.
final class WorkspaceClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        WorkspaceURLProtocolStub.requests = []
        WorkspaceURLProtocolStub.responder = nil
    }

    private func makeClient(
        gateway: URL? = URL(string: "https://api.orchet.ai")!
    ) -> WorkspaceClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkspaceURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return WorkspaceClient(
            baseURL: URL(string: "https://lumo.test")!,
            gatewayBaseURL: gateway,
            userIDProvider: { "user_test" },
            accessTokenProvider: { "supabase-jwt" },
            session: session
        )
    }

    func test_fetchToday_decodesEnvelope_and_routesViaGateway() async throws {
        WorkspaceURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/workspace/today")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-jwt")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-orchet-user-id"), "user_test")
            let body = """
            {
              "generated_at": "2026-05-14T08:00:00Z",
              "calendar": {"events":[],"source":"live","age_ms":1500},
              "email": {"messages":[],"source":"cached","age_ms":120000},
              "spotify": {"now_playing":null,"source":"live","age_ms":0},
              "youtube": {"channels":[],"source":"error","age_ms":null,"error":"oauth_expired"}
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let env = try await makeClient().fetchToday()
        XCTAssertEqual(env.calendar.source, "live")
        XCTAssertEqual(env.email.source, "cached")
        XCTAssertEqual(env.email.age_ms, 120_000)
        XCTAssertEqual(env.youtube.error, "oauth_expired")
    }

    func test_fetchToday_fallsBackToLegacyApiBase_whenNoGateway() async throws {
        WorkspaceURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://lumo.test/api/workspace/today")
            let body = """
            {
              "generated_at": "x",
              "calendar":{"events":[],"source":"live"},
              "email":{"messages":[],"source":"live"},
              "spotify":{"now_playing":null,"source":"live"},
              "youtube":{"channels":[],"source":"live"}
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        _ = try await makeClient(gateway: nil).fetchToday()
    }

    func test_fetchToday_unauthorized_surfacesUnauthorizedError() async {
        WorkspaceURLProtocolStub.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        do {
            _ = try await makeClient().fetchToday()
            XCTFail("expected unauthorized to throw")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_fetchOperations_decodesConnectorRows() async throws {
        WorkspaceURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/workspace/operations")
            let body = """
            {
              "generated_at": "2026-05-14T08:00:00Z",
              "connectors":[
                {"agent_id":"gmail","display_name":"Gmail","source":"oauth","status":"active","connected_at":"2026-04-01T00:00:00Z","last_used_at":null,"last_refreshed_at":null,"expires_at":null,"expires_in_seconds":null,"scope_count":3}
              ],
              "audit":[],
              "cache":[]
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let env = try await makeClient().fetchOperations()
        XCTAssertEqual(env.connectors.count, 1)
        XCTAssertEqual(env.connectors.first?.agent_id, "gmail")
        XCTAssertEqual(env.connectors.first?.status, "active")
    }
}

// MARK: - URLProtocol stub

final class WorkspaceURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
