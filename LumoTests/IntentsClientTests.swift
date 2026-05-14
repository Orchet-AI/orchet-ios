import XCTest
@testable import Lumo

final class IntentsClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IntentsURLProtocolStub.responder = nil
    }

    private func makeClient() -> IntentsClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntentsURLProtocolStub.self]
        return IntentsClient(
            baseURL: URL(string: "https://lumo.test")!,
            gatewayBaseURL: URL(string: "https://api.orchet.ai")!,
            userIDProvider: { "user_test" },
            accessTokenProvider: { "supabase-jwt" },
            session: URLSession(configuration: config)
        )
    }

    func test_list_decodesEnvelope_andRoutesViaGateway() async throws {
        IntentsURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/intents")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-jwt")
            let body = """
            {
              "intents": [
                {
                  "id": "i_1", "user_id": "u_1", "description": "Daily 9am",
                  "schedule_cron": "0 9 * * *", "timezone": "Asia/Kolkata",
                  "enabled": true, "last_fired_at": null, "next_fire_at": "2026-05-16T03:30:00Z",
                  "created_at": "2026-05-15T00:00:00Z", "updated_at": "2026-05-15T00:00:00Z"
                }
              ]
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let intents = try await makeClient().listIntents()
        XCTAssertEqual(intents.count, 1)
        XCTAssertEqual(intents.first?.schedule_cron, "0 9 * * *")
        XCTAssertEqual(intents.first?.timezone, "Asia/Kolkata")
    }

    func test_setEnabled_sendsPatch_andReturnsUpdatedIntent() async throws {
        IntentsURLProtocolStub.responder = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/intents/i_1")
            // Body inspection — verify enabled flag is forwarded.
            // URLProtocol exposes the body via httpBodyStream rather
            // than httpBody on the request, so read the stream out.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: 1024)
                    if read > 0 { data.append(buffer, count: read) }
                    if read <= 0 { break }
                }
                buffer.deallocate()
                stream.close()
                let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                XCTAssertEqual(dict?["enabled"] as? Bool, false)
            }
            let body = """
            {
              "intent": {
                "id": "i_1", "user_id": "u_1", "description": "Daily 9am",
                "schedule_cron": "0 9 * * *", "timezone": "Asia/Kolkata",
                "enabled": false, "last_fired_at": null, "next_fire_at": null,
                "created_at": "x", "updated_at": "y"
              }
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let updated = try await makeClient().setEnabled(id: "i_1", enabled: false)
        XCTAssertFalse(updated.enabled)
    }

    func test_delete_sends_DELETE_and_succeeds_on_ok_true() async throws {
        IntentsURLProtocolStub.responder = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/intents/i_1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"ok":true}"#.utf8))
        }
        try await makeClient().deleteIntent(id: "i_1")
    }

    func test_create_400_surfacesValidationDetail() async {
        IntentsURLProtocolStub.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"invalid_cron","detail":"Cron must have 5 fields"}"#.utf8))
        }
        do {
            _ = try await makeClient().createIntent(
                description: "Test", schedule_cron: "bogus", timezone: "UTC"
            )
            XCTFail("expected validation error")
        } catch let error as IntentsServiceError {
            if case .validation(let detail) = error {
                XCTAssertTrue(detail.contains("5 fields"))
            } else {
                XCTFail("unexpected: \(error)")
            }
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_401_throwsUnauthorized() async {
        IntentsURLProtocolStub.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await makeClient().listIntents()
            XCTFail("expected unauthorized")
        } catch let error as IntentsServiceError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

}

final class IntentsURLProtocolStub: URLProtocol {
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
