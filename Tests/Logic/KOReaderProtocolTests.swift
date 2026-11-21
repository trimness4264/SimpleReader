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
            XCTAssertEqual(body["device"] as? String, "Simple Reader")
            XCTAssertEqual(body["device_id"] as? String, "device")
            received.fulfill()
            return (200, #"{"document":"document","timestamp":200}"#)
        }
        var settings = SyncSettings()
        settings.url = origin
        settings.username = "reader"

        var book = sampleBook(position: readingPosition(2))
        book.pendingSync = true
        guard case .upload(let position) = SyncPolicy.decide(book: book, remote: nil) else { return XCTFail("Expected an upload") }
        let receipt = try await KOReaderSyncClient(settings: settings, password: "secret", http: http)
            .put(RemoteProgress(document: "document", progress: position.pointer, percentage: position.percentage,
                device: "Simple Reader", device_id: "device"))
        XCTAssertEqual(receipt.document, "document")
        XCTAssertEqual(receipt.timestamp, 200)
        await fulfillment(of: [received], timeout: 2)
    }

    func testOutOfRangeRemotePercentageIsRejected() async throws {
        let (http, origin) = HTTPStub.client(for: self) { _ in (200, #"{"progress":"3","percentage":7}"#) }
        var settings = SyncSettings()
        settings.url = origin

        do {
            _ = try await KOReaderSyncClient(settings: settings, password: "", http: http).get(document: "document")
            XCTFail("An invalid remote percentage must not become a reading position")
        } catch { XCTAssertEqual(error.localizedDescription, String(localized: "The server returned an invalid reading position.")) }
    }

    func testAuthenticationFailureIsReportedToCaller() async throws {
        let (http, origin) = HTTPStub.client(for: self) { _ in (401, "{}") }
        var settings = SyncSettings()
        settings.url = origin

        do {
            try await KOReaderSyncClient(settings: settings, password: "wrong", http: http).authorize()
            XCTFail("Unauthorized credentials must not be accepted")
        } catch { XCTAssertEqual(error.localizedDescription, String(localized: "Authentication failed. Check your username and password.")) }
    }
}
