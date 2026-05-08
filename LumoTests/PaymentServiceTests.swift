import XCTest
@testable import Lumo

final class PaymentServiceTests: XCTestCase {

    // MARK: - PaymentServiceStub

    func test_stub_presentPaymentSheet_addsMethod_andFirstIsDefault() async throws {
        let stub = PaymentServiceStub()
        let visa = try await stub.presentPaymentSheet(input: .init(brand: .visa, last4: "4242", expMonth: 12, expYear: 2030))
        XCTAssertEqual(visa.brand, .visa)
        XCTAssertEqual(visa.last4, "4242")
        XCTAssertTrue(visa.isDefault, "first added method should be default")
        XCTAssertEqual(stub.methods.count, 1)
    }

    func test_stub_presentPaymentSheet_secondAdded_isNotDefault() async throws {
        let stub = PaymentServiceStub()
        _ = try await stub.presentPaymentSheet(input: .init(brand: .visa, last4: "4242", expMonth: 12, expYear: 2030))
        let mc = try await stub.presentPaymentSheet(input: .init(brand: .mastercard, last4: "5555", expMonth: 1, expYear: 2031))
        XCTAssertFalse(mc.isDefault)
    }

    func test_stub_setDefault_promotesMethod_andDemotesPrevious() async throws {
        let stub = PaymentServiceStub()
        let first = try await stub.presentPaymentSheet(input: .init(brand: .visa, last4: "4242", expMonth: 12, expYear: 2030))
        let second = try await stub.presentPaymentSheet(input: .init(brand: .mastercard, last4: "5555", expMonth: 1, expYear: 2031))
        let promoted = try await stub.setDefaultPaymentMethod(id: second.id)
        XCTAssertTrue(promoted.isDefault)
        let listed = try await stub.listPaymentMethods()
        XCTAssertEqual(listed.first(where: { $0.id == first.id })?.isDefault, false)
        XCTAssertEqual(listed.first(where: { $0.id == second.id })?.isDefault, true)
    }

    func test_stub_remove_keepsListConsistent() async throws {
        let stub = PaymentServiceStub()
        let first = try await stub.presentPaymentSheet(input: .init(brand: .visa, last4: "4242", expMonth: 12, expYear: 2030))
        let second = try await stub.presentPaymentSheet(input: .init(brand: .mastercard, last4: "5555", expMonth: 1, expYear: 2031))
        try await stub.removePaymentMethod(id: first.id)
        let listed = try await stub.listPaymentMethods()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, second.id)
        XCTAssertTrue(listed.first?.isDefault ?? false, "remaining method should become default after removing prior default")
    }

    func test_stub_confirmTransaction_producesReceiptBoundToMethod() async throws {
        let stub = PaymentServiceStub()
        let visa = try await stub.presentPaymentSheet(input: .init(brand: .visa, last4: "4242", expMonth: 12, expYear: 2030))
        let receipt = try await stub.confirmTransaction(.init(
            amountCents: 4218,
            currency: "usd",
            paymentMethodId: visa.id,
            lineItems: [LineItem(label: "Room", amountCents: 4218)],
            transactionDigest: Data(repeating: 0xAA, count: 32),
            signedConfirmationToken: Data(repeating: 0xBB, count: 32)
        ))
        XCTAssertEqual(receipt.amountCents, 4218)
        XCTAssertEqual(receipt.currency, "usd")
        XCTAssertEqual(receipt.paymentMethodId, visa.id)
        XCTAssertEqual(receipt.status, .succeeded)
        XCTAssertTrue(receipt.paymentMethodLabel.contains("4242"))
    }

    func test_stub_confirmTransaction_unknownMethod_throws() async {
        let stub = PaymentServiceStub()
        do {
            _ = try await stub.confirmTransaction(.init(
                amountCents: 100,
                currency: "usd",
                paymentMethodId: "pm_nope",
                lineItems: [],
                transactionDigest: Data(repeating: 0x01, count: 32),
                signedConfirmationToken: Data(repeating: 0x02, count: 32)
            ))
            XCTFail("expected throw for unknown method")
        } catch {
            // expected
        }
    }

    // MARK: - PaymentService against URLProtocolMock

    func test_service_listPaymentMethods_decodesArray() async throws {
        let json = #"""
        {
          "methods": [
            {"id":"pm_test_1","brand":"visa","last4":"4242","expMonth":12,"expYear":2030,"isDefault":true,"addedAt":"2026-04-30T12:00:00.000Z"}
          ]
        }
        """#
        let session = mockSession([.init(method: "GET", path: "/api/payments/methods", status: 200, body: json)])
        let service = makeService(session: session)
        let methods = try await service.listPaymentMethods()
        XCTAssertEqual(methods.count, 1)
        XCTAssertEqual(methods.first?.brand, .visa)
        XCTAssertEqual(methods.first?.last4, "4242")
    }

    func test_service_createSetupIntent_returnsStubFlag() async throws {
        let json = #"""
        {"stub":true,"setupIntentId":"seti_test_abc","clientSecret":null,"customerId":"cus_test_xyz"}
        """#
        let session = mockSession([.init(method: "POST", path: "/api/payments/setup-intent", status: 200, body: json)])
        let service = makeService(session: session)
        let intent = try await service.createSetupIntent()
        XCTAssertTrue(intent.stub)
        XCTAssertNil(intent.clientSecret)
        XCTAssertEqual(intent.setupIntentId, "seti_test_abc")
    }

    func test_service_presentPaymentSheet_postsAndReturnsMethod() async throws {
        let json = #"""
        {"method":{"id":"pm_test_xyz","brand":"mastercard","last4":"5555","expMonth":1,"expYear":2031,"isDefault":false,"addedAt":"2026-04-30T12:00:00.000Z"}}
        """#
        let session = mockSession([.init(method: "POST", path: "/api/payments/methods", status: 201, body: json)])
        let service = makeService(session: session)
        let method = try await service.presentPaymentSheet(input: .init(brand: .mastercard, last4: "5555", expMonth: 1, expYear: 2031))
        XCTAssertEqual(method.brand, .mastercard)
    }

    func test_service_notConfigured_throws() async {
        let service = PaymentService(
            baseURL: URL(string: "http://localhost:9999")!,
            userIDProvider: { "anon" },
            isConfigured: false,
            session: .shared
        )
        do {
            _ = try await service.listPaymentMethods()
            XCTFail("expected notConfigured")
        } catch let error as PaymentServiceError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_service_badStatus_throwsWithCodeAndBody() async {
        let session = mockSession([.init(method: "GET", path: "/api/payments/methods", status: 503, body: #"{"error":"db_unavailable"}"#)])
        let service = makeService(session: session)
        do {
            _ = try await service.listPaymentMethods()
            XCTFail("expected throw")
        } catch let error as PaymentServiceError {
            if case .badStatus(let code, let body) = error {
                XCTAssertEqual(code, 503)
                XCTAssertNotNil(body)
            } else {
                XCTFail("expected .badStatus, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_service_confirmTransaction_sendsBase64Token_andHexDigest() async throws {
        let receiptJson = #"""
        {"ok":true,"receipt":{"id":"rcpt_test_1","transactionId":"txn_test_1","amountCents":1000,"currency":"usd","paymentMethodId":"pm_test_1","paymentMethodLabel":"VISA •• 4242","lineItems":[],"createdAt":"2026-04-30T12:00:00.000Z","status":"succeeded"}}
        """#
        let session = mockSession([.init(method: "POST", path: "/api/payments/confirm-transaction", status: 200, body: receiptJson)])
        let service = makeService(session: session)
        let receipt = try await service.confirmTransaction(.init(
            amountCents: 1000,
            currency: "usd",
            paymentMethodId: "pm_test_1",
            lineItems: [],
            transactionDigest: Data(repeating: 0x0A, count: 16),
            signedConfirmationToken: Data(repeating: 0x0B, count: 32)
        ))
        XCTAssertEqual(receipt.amountCents, 1000)
        // Verify the request body included the hex digest pattern.
        guard let request = PaymentURLProtocolMock.recorded.first(where: { $0.url?.path == "/api/payments/confirm-transaction" }) else {
            return XCTFail("no recorded confirm-transaction request")
        }
        let body = String(data: request.bodyData ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"transactionDigest\":\"0a0a"), "digest should be hex-encoded; body=\(body)")
        XCTAssertTrue(body.contains("\"signedConfirmationToken\":"), "token should be present in body")
    }

    // MARK: - P2H-5 contract parity tests
    //
    // These tests pin the confirm-transaction wire shape the gateway
    // forwards verbatim to svc-integrations. If any of these fail
    // after a P2H-5 edit, the body, digest encoding, signature
    // encoding, or auth-header behaviour has drifted from the
    // server-side contract — STOP and reconcile against
    // services/integrations/src/routes/payments/confirm-transaction.ts
    // before merging.

    func test_p2h5_confirmTransaction_fullBodyShape_legacyFallback() async throws {
        let receiptJson = #"""
        {"ok":true,"receipt":{"id":"rcpt_test_1","transactionId":"txn_test_1","amountCents":4218,"currency":"usd","paymentMethodId":"pm_test_visa","paymentMethodLabel":"VISA •• 4242","lineItems":[{"label":"Room","amountCents":4218}],"createdAt":"2026-04-30T12:00:00.000Z","status":"succeeded"}}
        """#
        let session = mockSession([.init(
            method: "POST",
            path: "/api/payments/confirm-transaction",
            status: 200,
            body: receiptJson
        )])
        // gatewayBaseURL: nil -> the migrated method's
        // viaGateway: true branch falls back to apps/web BFF path.
        let service = makeService(session: session)
        _ = try await service.confirmTransaction(.init(
            amountCents: 4218,
            currency: "usd",
            paymentMethodId: "pm_test_visa",
            lineItems: [LineItem(label: "Room", amountCents: 4218)],
            transactionDigest: Data(repeating: 0x0A, count: 32),
            signedConfirmationToken: Data(repeating: 0x0B, count: 64)
        ))
        guard let request = PaymentURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/api/payments/confirm-transaction"
        }) else {
            return XCTFail("no recorded confirm-transaction request on legacy fallback path")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.headers["x-lumo-user-id"], "test-user")
        guard let bodyData = request.bodyData,
              let parsed = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            return XCTFail("body was not parseable JSON")
        }
        // Exact key set the gateway forwards verbatim. Adding /
        // removing a key here is a P2H-5 stop condition.
        XCTAssertEqual(
            Set(parsed.keys),
            Set([
                "paymentMethodId",
                "amountCents",
                "currency",
                "lineItems",
                "transactionDigest",
                "signedConfirmationToken",
            ]),
            "confirm-transaction body keys drifted; this is a security contract change"
        )
        XCTAssertEqual(parsed["paymentMethodId"] as? String, "pm_test_visa")
        XCTAssertEqual(parsed["amountCents"] as? Int, 4218)
        XCTAssertEqual(parsed["currency"] as? String, "usd")
        let lineItems = parsed["lineItems"] as? [[String: Any]]
        XCTAssertEqual(lineItems?.count, 1)
        XCTAssertEqual(lineItems?.first?["label"] as? String, "Room")
        XCTAssertEqual(lineItems?.first?["amountCents"] as? Int, 4218)
        // 32-byte 0x0A repeated → 64 hex chars of "0a".
        XCTAssertEqual(
            parsed["transactionDigest"] as? String,
            String(repeating: "0a", count: 32),
            "transactionDigest must be lowercase hex of the input bytes"
        )
        // 64-byte 0x0B repeated → base64 of repeated 0x0B.
        let expectedTokenB64 = Data(repeating: 0x0B, count: 64).base64EncodedString()
        XCTAssertEqual(
            parsed["signedConfirmationToken"] as? String,
            expectedTokenB64,
            "signedConfirmationToken must be base64 of the input bytes"
        )
    }

    func test_p2h5_confirmTransaction_pathAndAuth_gatewayDirect() async throws {
        let receiptJson = #"""
        {"ok":true,"receipt":{"id":"rcpt_test_2","transactionId":"txn_test_2","amountCents":100,"currency":"usd","paymentMethodId":"pm_test_visa","paymentMethodLabel":"VISA •• 4242","lineItems":[],"createdAt":"2026-04-30T12:00:00.000Z","status":"succeeded"}}
        """#
        // gatewayBaseURL set -> the migrated method hits
        // /payments/confirm-transaction (no api/ prefix) on the
        // gateway. The mock matches by request.url.path so we set
        // both base + gateway to the same mock host but assert the
        // canonical path that the gateway-direct branch builds.
        let session = mockSession([.init(
            method: "POST",
            path: "/payments/confirm-transaction",
            status: 200,
            body: receiptJson
        )])
        let service = PaymentService(
            baseURL: URL(string: "http://localhost:9999")!,
            gatewayBaseURL: URL(string: "http://localhost:9999")!,
            userIDProvider: { "test-user" },
            accessTokenProvider: { "test-bearer-token" },
            isConfigured: true,
            session: session
        )
        _ = try await service.confirmTransaction(.init(
            amountCents: 100,
            currency: "usd",
            paymentMethodId: "pm_test_visa",
            lineItems: [],
            transactionDigest: Data(repeating: 0x01, count: 32),
            signedConfirmationToken: Data(repeating: 0x02, count: 64)
        ))
        guard let request = PaymentURLProtocolMock.recorded.first(where: {
            $0.url?.path == "/payments/confirm-transaction"
        }) else {
            return XCTFail("gateway-direct path /payments/confirm-transaction not hit")
        }
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-bearer-token")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        // Body shape must be identical to the legacy fallback path.
        guard let bodyData = request.bodyData,
              let parsed = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            return XCTFail("body was not parseable JSON")
        }
        XCTAssertEqual(
            Set(parsed.keys),
            Set([
                "paymentMethodId",
                "amountCents",
                "currency",
                "lineItems",
                "transactionDigest",
                "signedConfirmationToken",
            ]),
            "gateway-direct body keys must match the legacy fallback exactly"
        )
    }

    func test_p2h5_allFiveRoutes_legacyFallbackPaths() async throws {
        // Locks the fallback URLs the migrated methods produce when
        // gatewayBaseURL is nil. If a future edit accidentally drops
        // the `api/` prefix on the fallback branch, every method's
        // mock match would fail simultaneously — this test catches
        // it as one signal.
        let setupJson = #"""
        {"stub":true,"setupIntentId":"seti_x","clientSecret":null,"customerId":"cus_x"}
        """#
        let listJson = #"""
        {"methods":[]}
        """#
        let methodJson = #"""
        {"method":{"id":"pm_x","brand":"visa","last4":"4242","expMonth":12,"expYear":2030,"isDefault":true,"addedAt":"2026-04-30T12:00:00.000Z"}}
        """#
        let okJson = "{}"
        let session = mockSession([
            .init(method: "POST", path: "/api/payments/setup-intent", status: 200, body: setupJson),
            .init(method: "GET", path: "/api/payments/methods", status: 200, body: listJson),
            .init(method: "POST", path: "/api/payments/methods", status: 201, body: methodJson),
            .init(method: "POST", path: "/api/payments/methods/pm_x/set-default", status: 200, body: methodJson),
            .init(method: "DELETE", path: "/api/payments/methods/pm_x", status: 200, body: okJson),
        ])
        let service = makeService(session: session)
        _ = try await service.createSetupIntent()
        _ = try await service.listPaymentMethods()
        _ = try await service.presentPaymentSheet(input: .init(brand: .visa, last4: "4242", expMonth: 12, expYear: 2030))
        _ = try await service.setDefaultPaymentMethod(id: "pm_x")
        try await service.removePaymentMethod(id: "pm_x")
        let recordedPaths = PaymentURLProtocolMock.recorded.compactMap { $0.url?.path }
        XCTAssertEqual(recordedPaths.count, 5, "all five payment routes should have been called")
        XCTAssertTrue(recordedPaths.allSatisfy { $0.hasPrefix("/api/payments/") },
                      "fallback paths must keep the legacy `api/payments/` prefix on a nil-gateway build")
    }

    // MARK: - Helpers

    private func makeService(session: URLSession) -> PaymentService {
        PaymentService(
            baseURL: URL(string: "http://localhost:9999")!,
            userIDProvider: { "test-user" },
            isConfigured: true,
            session: session
        )
    }

    private func mockSession(_ responses: [PaymentURLProtocolMock.Stub]) -> URLSession {
        PaymentURLProtocolMock.queue = responses
        PaymentURLProtocolMock.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaymentURLProtocolMock.self]
        return URLSession(configuration: config)
    }
}

// MARK: - URLProtocol mock

final class PaymentURLProtocolMock: URLProtocol {
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
