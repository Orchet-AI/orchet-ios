import XCTest
@testable import Lumo

/// HTTP contract tests for CostClient. Uses a URLProtocol stub so
/// request-formation + decode path are exercised without hitting
/// the network.
final class CostClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CostURLProtocolStub.responder = nil
    }

    private func makeClient(gateway: URL? = URL(string: "https://api.orchet.ai")!) -> CostClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CostURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return CostClient(
            baseURL: URL(string: "https://lumo.test")!,
            gatewayBaseURL: gateway,
            userIDProvider: { "user_test" },
            accessTokenProvider: { "supabase-jwt" },
            session: session
        )
    }

    func test_fetchDashboard_decodesEnvelope_andRoutesViaGateway() async throws {
        CostURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/cost/dashboard")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-jwt")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-orchet-user-id"), "user_test")
            let body = """
            {
              "budget": {"tier":"free","dailyCapUsd":1.0,"monthlyCapUsd":20.0,"softCap":true},
              "today": {"window":"daily","windowStartAt":"2026-05-15T00:00:00Z","windowEndAt":"2026-05-16T00:00:00Z","costUsdTotal":0.42,"source":"rollup_plus_delta"},
              "month": {"window":"monthly","windowStartAt":"2026-05-01T00:00:00Z","windowEndAt":"2026-06-01T00:00:00Z","costUsdTotal":4.20,"source":"ledger"},
              "daily": [{"date":"2026-05-14","totalUsd":0.31,"invocations":7}],
              "agents": [{"agentId":"lumo-flights","totalUsd":2.10,"invocations":4}],
              "recent": [{"createdAt":"2026-05-15T12:00:00Z","agentId":"lumo-flights","capabilityId":"search","totalUsd":0.04,"status":"success","modelUsed":"haiku-4-5"}]
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let env = try await makeClient().fetchDashboard()
        XCTAssertEqual(env.budget.tier, "free")
        XCTAssertEqual(env.today.costUsdTotal, 0.42, accuracy: 0.001)
        XCTAssertEqual(env.agents.first?.agentId, "lumo-flights")
        XCTAssertEqual(env.recent.first?.capabilityId, "search")
    }

    func test_fetchDashboard_fallsBackToLegacyAPI_whenNoGateway() async throws {
        CostURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://lumo.test/api/cost/dashboard")
            let body = """
            {
              "budget": {"tier":"free","dailyCapUsd":null,"monthlyCapUsd":null,"softCap":false},
              "today": {"window":"daily","windowStartAt":"x","windowEndAt":"x","costUsdTotal":0,"source":"none"},
              "month": {"window":"monthly","windowStartAt":"x","windowEndAt":"x","costUsdTotal":0,"source":"none"},
              "daily": [], "agents": [], "recent": []
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        _ = try await makeClient(gateway: nil).fetchDashboard()
    }

    func test_fetchDashboard_unauthorized_throwsUnauthorized() async {
        CostURLProtocolStub.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeClient().fetchDashboard()
            XCTFail("expected unauthorized")
        } catch let error as CostServiceError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}

final class CostURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let r = Self.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "stub", code: -1))
            return
        }
        let (resp, data) = r(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
