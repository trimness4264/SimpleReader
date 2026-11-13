import XCTest
import PDFKit
@testable import SimpleReader

@MainActor final class PageTurnTests: XCTestCase {
    func testCompletedPDFTurnPersistsNextPageAsPendingProgress() async throws {
        let store = try library()
        let source = try pdfFile(in: temporaryDirectory())
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: source)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")

        await session.turn(forward: true)
        await session.flush()

        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 1)
        XCTAssertEqual(store.book(book.id)?.pendingSync, true)
        XCTAssertFalse(session.container.isTurningPage)
        await session.close()
    }

    func testCancelledEPUBGesturePreservesSavedPositionAndUnlocksReader() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        let initial = try XCTUnwrap(store.book(book.id)?.position)

        XCTAssertTrue(session.container.beginPageTurn(translation: CGPoint(x: -30, y: 0)))
        XCTAssertFalse(session.container.beginPageTurn(translation: CGPoint(x: -30, y: 0)))
        session.container.updatePageTurn(translation: CGPoint(x: -30, y: 0))
        session.container.cancelPageTransition()
        await session.flush()

        XCTAssertEqual(store.book(book.id)?.position?.xpointer, initial.xpointer)
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        XCTAssertFalse(session.container.isTurningPage)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)
        await session.close()
    }

    func testPDFTwoPageLayoutKeepsTheSelectedPageAtTheReadableTop() async throws {
        let controller = UIViewController()
        let window = present(controller)
        defer { window.isHidden = true }
        let source = try pdfFile(in: temporaryDirectory())
        let insets = UIEdgeInsets(top: 44, left: 0, bottom: 30, right: 0)
        let reader = try PDFReader(url: source, in: controller.view, twoPages: false, insets: insets) { _, _ in }
        _ = try await reader.open(at: 2, updatedAt: Date())
        let checkpoint = try XCTUnwrap(reader.checkpoint(at: 2))

        controller.view.frame.size = CGSize(width: 980, height: 640)
        reader.updateLayout(twoPages: true)
        let position = try await reader.move(to: .checkpoint(checkpoint))

        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? PDFView }.first)
        let page = try XCTUnwrap(view.document?.page(at: 2))
        XCTAssertEqual(view.displayMode, .twoUpContinuous)
        XCTAssertEqual(position.pdfPage, 2)
        XCTAssertEqual(view.convert(page.bounds(for: view.displayBox), from: page).minY, insets.top, accuracy: 2)
    }
}
