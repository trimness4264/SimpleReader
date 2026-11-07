import XCTest
@testable import SimpleReader

final class HTTPPolicyTests: XCTestCase {
    func testCredentialsStayOnTheirOriginalSchemeHostAndPort() throws {
        let origin = URL(string: "https://books.example.com")!
        let credentials = ServerCredentials(origin: origin, username: "reader", password: "secret")
        let http = HTTPClient()
        let sameOrigin = URL(string: "https://books.example.com:443/book.epub")!
        XCTAssertEqual(try http.request(sameOrigin, credentials: credentials).value(forHTTPHeaderField: "Authorization"), "Basic cmVhZGVyOnNlY3JldA==")
        for address in ["https://cdn.example.com/book.epub", "https://books.example.com:8443/book.epub"] {
            let request = try http.request(URL(string: address)!, credentials: credentials)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), address)
        }
    }

    func testCrossOriginRedirectRemovesAllAccountHeaders() throws {
        let completed = expectation(description: "Redirect decision returned")
        let origin = URL(string: "https://books.example.com")!
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var request = URLRequest(url: URL(string: "https://cdn.example.com/book.epub")!)
        let headers = ["Authorization", "X-Auth-User", "X-Auth-Key", "Cookie"]
        for name in headers { request.setValue("private", forHTTPHeaderField: name) }
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }

        CredentialGuard(origin: origin).urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: request) { redirected in
            XCTAssertNotNil(redirected)
            for name in headers { XCTAssertNil(redirected?.value(forHTTPHeaderField: name), name) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testPlainHTTPIsLimitedToLocalServers() throws {
        for host in ["localhost", "calibre.local", "192.168.1.1", "172.16.0.1", "172.31.255.254", "[::1]", "[fd00::1]"] {
            XCTAssertNoThrow(try NetworkPolicy.validate(URL(string: "http://\(host)")!), host)
        }
        for address in ["http://example.com", "http://172.15.255.254", "http://172.32.0.1", "ftp://192.168.1.1", "https://user:password@example.com"] {
            XCTAssertThrowsError(try NetworkPolicy.validate(URL(string: address)!), address)
        }
    }
}
