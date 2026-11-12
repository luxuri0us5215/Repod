import XCTest
@testable import iPodPlayer

final class NetEaseConnectionModeTests: XCTestCase {
    func testStoredModeWins() {
        XCTAssertEqual(
            NetEaseConnectionMode.resolved(storedRaw: "direct", address: "http://mac:3000"),
            .direct
        )
        XCTAssertEqual(
            NetEaseConnectionMode.resolved(storedRaw: "gateway", address: ""),
            .gateway
        )
    }

    func testLegacyAddressMigratesToGateway() {
        XCTAssertEqual(
            NetEaseConnectionMode.resolved(storedRaw: nil, address: "http://mac:3000"),
            .gateway
        )
    }

    func testFreshInstallStartsDirect() {
        XCTAssertEqual(NetEaseConnectionMode.resolved(storedRaw: nil, address: nil), .direct)
        XCTAssertEqual(NetEaseConnectionMode.resolved(storedRaw: "", address: "  "), .direct)
    }
}

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class NetEaseGatewayTransportTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testCookieTravelsAsFormBodyNotHeader() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            return (200, ["Content-Type": "application/json"], Data(#"{"code":200,"data":{}}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = NetEaseGatewayTransport(
            baseURL: "http://127.0.0.1:3000",
            session: URLSession(configuration: configuration)
        )
        _ = try await transport.send(
            path: "/user/playlist",
            parameters: ["uid": "42", "limit": "5"],
            cookie: "MUSIC_U=abc+def",
            timeout: 5
        )
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/user/playlist")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = String(data: MockURLProtocol.body(of: request), encoding: .utf8) ?? ""
        XCTAssertTrue(body.hasPrefix("cookie="))
        XCTAssertTrue(body.contains("abc%2Bdef"))
        let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "uid" }?.value, "42")
        XCTAssertNotNil(components?.queryItems?.first { $0.name == "timestamp" })
    }

    @MainActor
    func testNoCookieKeepsGETWithQuery() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            return (200, ["Content-Type": "application/json"], Data(#"{"code":200}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let transport = NetEaseGatewayTransport(
            baseURL: "http://127.0.0.1:3000",
            session: URLSession(configuration: configuration)
        )
        _ = try await transport.send(
            path: "/cloudsearch",
            parameters: ["keywords": "jay"],
            cookie: "",
            timeout: 5
        )
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
    }
}
