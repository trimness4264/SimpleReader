import XCTest
@testable import SimpleReader

private final class MockURLProtocol: URLProtocol {
    static var handle: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handle!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class NetworkTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handle = nil; super.tearDown() }
    func http() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return HTTPClient(configuration: config)
    }
    func testKOReaderAuthenticationAndPDFWirePage() async throws {
        var settings = SyncSettings(); settings.username = "tester"
        let client = KOReaderSyncClient(settings: settings, password: "secret", http: http())
        MockURLProtocol.handle = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-User"), "tester")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Key"), BookHashing.md5(Data("secret".utf8)))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.koreader.v1+json")
            XCTAssertEqual(request.url?.path, "/users/auth")
            return (200, Data("{}".utf8))
        }
        try await client.authorize()
        MockURLProtocol.handle = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/syncs/progress")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 2048)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            }
            let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            XCTAssertEqual(payload["progress"] as? String, "3")
            XCTAssertEqual(payload["document"] as? String, "digest")
            XCTAssertEqual(payload["device_id"] as? String, "device")
            return (200, Data("{}".utf8))
        }
        try await client.put(document: "digest", position: ReadingPosition(progression: 0.3, pdfPage: 2, updatedAt: Date()), deviceID: "device")
    }
    func testMissingInvalidAndUnauthorizedRemoteProgress() async throws {
        let client = KOReaderSyncClient(settings: SyncSettings(), password: "", http: http())
        MockURLProtocol.handle = { _ in (200, Data("{}".utf8)) }
        let absent = try await client.get(document: "none"); XCTAssertNil(absent)
        MockURLProtocol.handle = { _ in (200, Data("{\"progress\":\"bad\",\"percentage\":7}".utf8)) }
        do { _ = try await client.get(document: "bad"); XCTFail("Out-of-range percentage must fail") } catch {}
        MockURLProtocol.handle = { _ in (401, Data("{}".utf8)) }
        do { try await client.authorize(); XCTFail("401 must fail") } catch { XCTAssertTrue(error.localizedDescription.contains("认证失败")) }
        MockURLProtocol.handle = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await client.get(document: "offline"); XCTFail("Offline must fail") } catch {}
    }
    func testOpenSearchAndQueryEscaping() async throws {
        let client = OPDSClient(http: http())
        MockURLProtocol.handle = { _ in (200, Data("<OpenSearchDescription xmlns='http://a9.com/-/spec/opensearch/1.1/'><Url type='application/atom+xml' template='https://example.com/search?q={searchTerms}&amp;page={startPage?}'/></OpenSearchDescription>".utf8)) }
        let link = OPDSLink(url: URL(string: "https://example.com/search.xml")!, rel: "search", type: "application/opensearchdescription+xml", title: "")
        let url = try await client.searchURL(link: link, query: "中文 & a+b", credentials: nil)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "中文 & a+b")
        XCTAssertEqual(items.first { $0.name == "page" }?.value, "1")
    }
}
