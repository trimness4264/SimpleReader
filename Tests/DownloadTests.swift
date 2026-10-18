import XCTest
import UIKit
import SwiftUI
@testable import SimpleReader

@MainActor final class DownloadTests: XCTestCase {
    func testDetailShowsLiveProgressAndTheImportedBook() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library"), inMemory: true)
        let pdf = try makePDF(in: root)
        var release: CheckedContinuation<Void, Never>?
        let environment = try AppEnvironment(store: store) { request, progress in
            progress(0.4)
            await withCheckedContinuation { release = $0 }
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: pdf, to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/pdf"])!)
        }
        let acquisition = link("detail")
        let entry = OPDSEntry(id: "detail", title: "下载测试图书", author: "作者", summary: "在详情页查看下载进度，完成后打开阅读。", links: [acquisition])
        let server = OPDSServer(id: UUID(), name: "Test", url: URL(string: "https://example.com")!, username: "")
        let model = CatalogModel(server: server, url: server.url, client: environment.opds)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationView {
            EntryView(entry: entry, model: model, environment: environment)
        }.navigationViewStyle(.stack))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        environment.downloads.enqueue(title: entry.title, link: acquisition, credentials: nil)
        try await wait { environment.downloads.job(for: acquisition)?.progress == 0.4 && release != nil }
        try await Task.sleep(nanoseconds: 200_000_000)
        func attachScreenshot(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachScreenshot("Detail downloading")
        release?.resume()
        release = nil
        try await wait { environment.downloads.job(for: acquisition)?.state == .finished }
        let id = try XCTUnwrap(environment.downloads.job(for: acquisition)?.bookID)
        XCTAssertEqual(store.book(id)?.format, .pdf)
        try await Task.sleep(nanoseconds: 200_000_000)
        attachScreenshot("Detail ready to read")
    }
    func testEachFormatKeepsItsImportedBookAndRepeatedImportReusesLibraryBook() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library"), inMemory: true)
        let pdf = try makePDF(in: root)
        let epub = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let importer = BookImportService(store: store, readium: ReadiumService())
        let manager = DownloadManager(http: HTTPClient(), importer: importer) { request, progress in
            let source = request.value(forHTTPHeaderField: "Accept") == "application/pdf" ? pdf : epub
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: source, to: temporary)
            progress(1)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": request.value(forHTTPHeaderField: "Accept")!])!)
        }
        let pdfLink = link("book", type: "application/pdf")
        let epubLink = link("book", type: "application/epub+zip")
        manager.enqueue(title: "PDF", link: pdfLink, credentials: nil)
        manager.enqueue(title: "EPUB", link: epubLink, credentials: nil)
        manager.enqueue(title: "duplicate", link: pdfLink, credentials: nil)
        XCTAssertEqual(manager.jobs.count, 2, "Repeated taps must reuse the active download, while different formats remain independent")
        try await wait { manager.jobs.allSatisfy { $0.state == .finished } }
        let pdfID = try XCTUnwrap(manager.job(for: pdfLink)?.bookID)
        let epubID = try XCTUnwrap(manager.job(for: epubLink)?.bookID)
        XCTAssertNotEqual(pdfID, epubID)
        XCTAssertEqual(store.book(pdfID)?.format, .pdf)
        XCTAssertEqual(store.book(epubID)?.format, .epub)
        manager.enqueue(title: "PDF again", link: pdfLink, credentials: nil)
        try await wait { manager.job(for: pdfLink)?.state == .finished }
        XCTAssertEqual(manager.job(for: pdfLink)?.bookID, pdfID)
        XCTAssertEqual(store.books.count, 2)
        XCTAssertEqual(manager.job(for: pdfLink)?.progress, 1)
    }

    func testFailureRetriesSameJobAndClearsErrorAfterImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library"), inMemory: true)
        let pdf = try makePDF(in: root)
        var attempts = 0
        let manager = DownloadManager(http: HTTPClient(), importer: BookImportService(store: store, readium: ReadiumService())) { request, _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: pdf, to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/pdf"])!)
        }
        let acquisition = link("retry")
        manager.enqueue(title: "Retry", link: acquisition, credentials: nil)
        try await wait { manager.job(for: acquisition)?.state == .failed }
        let failed = try XCTUnwrap(manager.job(for: acquisition))
        XCTAssertNotNil(failed.error)
        XCTAssertNil(failed.bookID)
        XCTAssertTrue(store.books.isEmpty)
        manager.retry(failed.id)
        try await wait { manager.job(for: acquisition)?.state == .finished }
        let finished = try XCTUnwrap(manager.job(for: acquisition))
        XCTAssertEqual(finished.id, failed.id)
        XCTAssertNil(finished.error)
        XCTAssertNotNil(finished.bookID.flatMap { store.book($0) })
        XCTAssertEqual(manager.jobs.count, 1)
        XCTAssertEqual(attempts, 2)
    }

    func testCancelQueuedAndRunningDownloadsThenRetryWithoutImportingCancelledFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root.appendingPathComponent("library"), inMemory: true)
        let pdf = try makePDF(in: root)
        var attempts = 0
        var stopped = 0
        let manager = DownloadManager(http: HTTPClient(), importer: BookImportService(store: store, readium: ReadiumService())) { request, progress in
            attempts += 1
            if attempts <= 2 {
                defer { stopped += 1 }
                progress(0.4)
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: pdf, to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/pdf"])!)
        }
        let first = link("first"), second = link("second"), queued = link("queued")
        for acquisition in [first, second, queued] { manager.enqueue(title: "Cancel", link: acquisition, credentials: nil) }
        try await wait { manager.job(for: first)?.progress == 0.4 }
        XCTAssertEqual(manager.job(for: queued)?.state, .queued)
        manager.cancel(try XCTUnwrap(manager.job(for: queued)?.id))
        manager.cancel(try XCTUnwrap(manager.job(for: first)?.id))
        manager.cancel(try XCTUnwrap(manager.job(for: second)?.id))
        try await wait { stopped == 2 }
        XCTAssertTrue(manager.jobs.allSatisfy { $0.state == .cancelled })
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertEqual(attempts, 2, "A queued cancellation must never start a transfer")
        manager.retry(try XCTUnwrap(manager.job(for: first)?.id))
        try await wait { manager.job(for: first)?.state == .finished }
        XCTAssertEqual(store.books.count, 1)
        XCTAssertNotNil(manager.job(for: first)?.bookID)
        manager.clearHistory()
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func makePDF(in root: URL) throws -> URL {
        let file = root.appendingPathComponent("sample.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: file) { context in
            context.beginPage()
            ("Download test" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
        }
        return file
    }
    private func link(_ path: String, type: String = "application/pdf") -> OPDSLink {
        OPDSLink(url: URL(string: "https://example.com/\(path)")!, rel: "http://opds-spec.org/acquisition", type: type)
    }
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Download did not reach the expected state")
        throw AppFailure("下载测试超时")
    }
}
