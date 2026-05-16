import XCTest
@testable import Lumo

/// HTTP contract tests for `MemoryMailService` — the iOS surface
/// for Phase C of ORCHET-IOS-MEMORY-LEARNING. Uses a URLProtocol
/// stub so request shape (URL, headers, body) and decode + error
/// paths are exercised without hitting the network.
@MainActor
final class MemoryMailServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MemoryMailURLProtocolStub.responder = nil
    }

    private func makeService(
        gateway: URL? = URL(string: "https://api.orchet.ai")!
    ) -> MemoryMailService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryMailURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let service = MemoryMailService()
        service.configure(
            gatewayBaseURL: gateway,
            userIDProvider: { "user_test" },
            accessTokenProvider: { "supabase-jwt" },
            session: session
        )
        return service
    }

    // MARK: fetchEnabled

    func test_fetchEnabled_returnsServerFlag() async {
        MemoryMailURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/memory/sources/mail")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-jwt")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-orchet-user-id"), "user_test")
            let body = "{\"enabled\":true}"
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(body.utf8)
            )
        }
        let result = await makeService().fetchEnabled()
        XCTAssertEqual(result, true)
    }

    func test_fetchEnabled_returnsFalseFromServer() async {
        MemoryMailURLProtocolStub.responder = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"enabled\":false}".utf8)
            )
        }
        let result = await makeService().fetchEnabled()
        XCTAssertEqual(result, false)
    }

    func test_fetchEnabled_returnsNilOn401() async {
        MemoryMailURLProtocolStub.responder = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let result = await makeService().fetchEnabled()
        XCTAssertNil(result)
    }

    func test_fetchEnabled_returnsNilWhenGatewayMissing() async {
        let result = await makeService(gateway: nil).fetchEnabled()
        XCTAssertNil(result)
    }

    // MARK: setEnabled

    func test_setEnabled_sendsPatchWithJsonBody() async {
        var seenBody: Data?
        MemoryMailURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/memory/sources/mail")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            seenBody = Self.readBody(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"ok\":true,\"enabled\":true}".utf8)
            )
        }
        let ok = await makeService().setEnabled(true)
        XCTAssertTrue(ok)
        XCTAssertNotNil(seenBody)
        let json = try? JSONSerialization.jsonObject(with: seenBody ?? Data()) as? [String: Any]
        XCTAssertEqual(json?["enabled"] as? Bool, true)
    }

    func test_setEnabled_returnsFalseOnServerError() async {
        MemoryMailURLProtocolStub.responder = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let ok = await makeService().setEnabled(false)
        XCTAssertFalse(ok)
    }

    // MARK: forgetEverything

    func test_forgetEverything_postsToForgetEndpoint() async {
        MemoryMailURLProtocolStub.responder = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.orchet.ai/memory/mail/forget")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer supabase-jwt")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"ok\":true,\"deleted\":4}".utf8)
            )
        }
        let ok = await makeService().forgetEverything()
        XCTAssertTrue(ok)
    }

    func test_forgetEverything_returnsFalseOnFailure() async {
        MemoryMailURLProtocolStub.responder = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let ok = await makeService().forgetEverything()
        XCTAssertFalse(ok)
    }

    // MARK: helpers

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class MemoryMailURLProtocolStub: URLProtocol {
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
