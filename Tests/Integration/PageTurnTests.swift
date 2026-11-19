import XCTest
import PDFKit
@testable import SimpleReader

@MainActor final class PageTurnTests: XCTestCase {
    func testPDFButtonTurnPersistsMovementAndPreservesHistoryAtEnd() async throws {
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

        let lastPage = try XCTUnwrap(session.pdfPageCount)
        let jumped = await session.jump(toPage: lastPage)
        XCTAssertTrue(jumped)
        let savedEnd = try XCTUnwrap(store.book(book.id)?.position)
        await session.turn(forward: true)
        XCTAssertEqual(session.currentPDFPage, lastPage)
        XCTAssertEqual(store.book(book.id)?.position, savedEnd)
        XCTAssertTrue(session.canReturnToPreviousPosition)
        XCTAssertFalse(session.container.isTurningPage)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)

        await session.returnToPreviousPosition()
        XCTAssertEqual(session.currentPDFPage, 2)
        XCTAssertFalse(session.canReturnToPreviousPosition)
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
        XCTAssertTrue(session.canBeginPageTurn(isGesture: true))
        await session.close()
    }

    func testBackgroundBeforePDFTurnCommitsRestoresOrigin() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        window.windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window.makeKeyAndVisible()
        session.container.view.layoutIfNeeded()
        defer { window.isHidden = true }
        await session.load()
        let origin = try XCTUnwrap(store.book(book.id)?.position)

        // Interrupt after the renderer moves and before the container confirms completion.
        let turn = Task { await session.turn(forward: true) }
        let deadline = ContinuousClock.now + .seconds(5)
        while session.currentPDFPage != 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.currentPDFPage, 2)
        XCTAssertTrue(session.container.isTurningPage)
        XCTAssertEqual(store.book(book.id)?.position, origin)
        await session.background()
        await turn.value
        XCTAssertFalse(session.container.isTurningPage)
        XCTAssertTrue(session.isRestoring)
        XCTAssertFalse(session.container.view.isUserInteractionEnabled)
        XCTAssertEqual(store.book(book.id)?.position, origin)

        session.container.beginAppearanceTransition(false, animated: false)
        session.container.endAppearanceTransition()
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        let synchronized = expectation(description: "Foreground sync ran after position recovery")
        server.onRead = {
            XCTAssertFalse(session.isRestoring)
            XCTAssertEqual(session.currentPDFPage, 1)
            synchronized.fulfill()
        }
        await session.foreground()
        XCTAssertTrue(session.isRestoring)
        XCTAssertFalse(session.container.view.isUserInteractionEnabled)

        session.container.beginAppearanceTransition(true, animated: false)
        session.container.endAppearanceTransition()
        await fulfillment(of: [synchronized], timeout: 10)
        server.onRead = nil

        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertEqual(store.book(book.id)?.position, origin)
        XCTAssertFalse(session.isRestoring)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)
        XCTAssertTrue(session.canBeginPageTurn(isGesture: false))
        await session.close()
    }

    func testCompletedEPUBGesturePersistsSettledPositionAndUnlocksReader() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = present(session.container)
        // Readium needs a scene to render the page confirmed after the gesture.
        window.windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window.makeKeyAndVisible()
        session.container.view.layoutIfNeeded()
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        let initial = try XCTUnwrap(store.book(book.id)?.position?.xpointer)
        let translation = CGPoint(x: -window.bounds.width * 0.7, y: 0)

        XCTAssertTrue(session.container.beginPageTurn(translation: translation))
        session.container.updatePageTurn(translation: translation)
        session.container.finishPageTurn(translation: translation, velocity: CGPoint(x: -900, y: 0))
        let deadline = ContinuousClock.now + .seconds(10)
        while session.container.isTurningPage && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(session.container.isTurningPage)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)
        XCTAssertNil(session.error)
        let settled = try XCTUnwrap(store.book(book.id)?.position?.xpointer)
        XCTAssertNotEqual(settled, initial)
        XCTAssertEqual(store.book(book.id)?.pendingSync, true)
        await session.close()
    }

    func testPDFTwoPageLayoutKeepsTheSelectedPageAtTheReadableTop() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let controller = session.container
        let window = present(controller)
        defer { window.isHidden = true }
        let insets = UIEdgeInsets(top: 44, left: 0, bottom: 30, right: 0)
        session.updateScrollInsets(insets)
        await session.load()
        let jumped = await session.jump(toPage: 3)
        XCTAssertTrue(jumped)
        let saved = try XCTUnwrap(store.book(book.id)?.position)

        controller.traitOverrides.userInterfaceIdiom = .pad
        controller.view.frame.size = CGSize(width: 980, height: 640)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(session.isRestoring)
        let restored = expectChange("PDF restored after changing to a two-page layout") { _ = session.isRestoring }
        await fulfillment(of: [restored], timeout: 10)

        let view = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? PDFView }.first)
        let page = try XCTUnwrap(view.document?.page(at: 2))
        XCTAssertNil(session.recoveryError)
        XCTAssertEqual(view.displayMode, .twoUpContinuous)
        XCTAssertEqual(session.currentPDFPage, 3)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertEqual(view.convert(page.bounds(for: view.displayBox), from: page).minY, insets.top, accuracy: 2)
        await session.close()
    }
}
