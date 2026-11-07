import XCTest
@testable import SimpleReader

@MainActor final class DownloadLifecycleTests: XCTestCase {
    func testCancelledTransferCannotImportItsLateResponse() async throws {
        let store = try library()
        let file = try pdfFile(in: temporaryDirectory())
        let started = expectation(description: "Transfer started")
        var finish: CheckedContinuation<Void, Never>?
        let link = downloadLink()
        let response = HTTPURLResponse(url: link.url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!
        let manager = DownloadManager(http: HTTPClient(), importer: BookImportService(store: store, readium: ReadiumService())) { _, _ in
            await withCheckedContinuation { finish = $0; started.fulfill() }
            return (file, response)
        }
        manager.enqueue(title: "Book", link: link, credentials: nil)
        await fulfillment(of: [started], timeout: 5)
        let job = try XCTUnwrap(manager.job(for: link))

        manager.cancel(job.id)
        finish?.resume()
        let removed = expectation(for: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: file.path)
        }, evaluatedWith: nil)
        await fulfillment(of: [removed], timeout: 5)

        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(manager.job(for: link)?.bookID)
        XCTAssertEqual(manager.job(for: link)?.state, .cancelled)
    }

    func testFailedDownloadCanRetryAndExposeImportedBook() async throws {
        let store = try library()
        let file = try pdfFile(in: temporaryDirectory())
        let link = downloadLink()
        var shouldFail = true
        let response = HTTPURLResponse(url: link.url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"])!
        let manager = DownloadManager(http: HTTPClient(), importer: BookImportService(store: store, readium: ReadiumService())) { _, _ in
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return (file, response)
        }
        manager.enqueue(title: "Book", link: link, credentials: nil)
        await waitForValue(manager.$jobs, description: "Download failed") { $0.first?.state == .failed }
        let failed = try XCTUnwrap(manager.job(for: link))
        shouldFail = false

        manager.retry(failed.id)
        await waitForValue(manager.$jobs, description: "Book imported") { $0.first?.state == .finished }

        let finished = try XCTUnwrap(manager.job(for: link))
        XCTAssertEqual(finished.id, failed.id)
        XCTAssertNil(finished.error)
        let id = try XCTUnwrap(finished.bookID)
        XCTAssertEqual(store.book(id)?.format, .pdf)
    }

    private func downloadLink() -> OPDSLink {
        OPDSLink(url: URL(string: "https://books.example.com/book.pdf")!, rel: "http://opds-spec.org/acquisition", type: "application/pdf")
    }
}
