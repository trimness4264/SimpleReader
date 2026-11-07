import XCTest
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
}
