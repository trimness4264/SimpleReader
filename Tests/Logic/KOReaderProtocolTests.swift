import XCTest
@testable import SimpleReader

final class KOReaderProtocolTests: XCTestCase {
    func testPDFUploadUsesOneBasedPageAndKOReaderAuthentication() async throws {
        let received = expectation(description: "Progress received by server")
        let (http, origin) = HTTPStub.client(for: self) { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/syncs/progress")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-User"), "reader")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Key"), "5ebe2294ecd0e0f08eab7690d2a6ee69")
            let body = try request.jsonBody()
            XCTAssertEqual(body["progress"] as? String, "3")
            XCTAssertEqual(body["percentage"] as? Double, 0.25)
            XCTAssertEqual(body["document"] as? String, "document")
            XCTAssertEqual(body["device_id"] as? String, "device")
            received.fulfill()
            return (200, "{}")
        }
        var settings = SyncSettings()
        settings.url = origin
        settings.username = "reader"

        try await KOReaderSyncClient(settings: settings, password: "secret", http: http)
            .put(document: "document", position: readingPosition(2), deviceID: "device")
        await fulfillment(of: [received], timeout: 2)
    }

    func testOutOfRangeRemotePercentageIsRejected() async throws {
        let (http, origin) = HTTPStub.client(for: self) { _ in (200, #"{"progress":"3","percentage":7}"#) }
        var settings = SyncSettings()
        settings.url = origin

        do {
            _ = try await KOReaderSyncClient(settings: settings, password: "", http: http).get(document: "document")
            XCTFail("An invalid remote percentage must not become a reading position")
        } catch { XCTAssertEqual(error.localizedDescription, "服务器阅读位置无效") }
    }

    func testAuthenticationFailureIsReportedToCaller() async throws {
        let (http, origin) = HTTPStub.client(for: self) { _ in (401, "{}") }
        var settings = SyncSettings()
        settings.url = origin

        do {
            try await KOReaderSyncClient(settings: settings, password: "wrong", http: http).authorize()
            XCTFail("Unauthorized credentials must not be accepted")
        } catch { XCTAssertEqual(error.localizedDescription, "认证失败，请检查账号与密码") }
    }
}
