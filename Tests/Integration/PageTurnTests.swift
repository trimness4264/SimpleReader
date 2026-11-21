import Combine
import XCTest
import PDFKit
import ReadiumShared
import WebKit
@testable import SimpleReader

@MainActor final class PageTurnTests: XCTestCase {
    func testReplacingContentCancelsOldTurnWithoutUnlockingNextTurn() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "This regression exercises animated snapshots.")
        let controller = ReaderContainerController()
        let window = present(controller)
        window.windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let delegate = SuspendedTurnDelegate()
        controller.pageTurnDelegate = delegate
        let original = UIViewController()
        let replacement = UIViewController()
        original.view.backgroundColor = .white
        replacement.view.backgroundColor = .white
        controller.replaceChild(with: original)
        XCTAssertNotNil(original.view.snapshotView(afterScreenUpdates: true))

        let firstStarted = expectation(description: "Original turn reached navigation")
        let (firstGate, releaseFirst) = AsyncStream<Void>.makeStream()
        defer { releaseFirst.finish() }
        delegate.onMove = {
            firstStarted.fulfill()
            for await _ in firstGate { break }
            return true
        }
        let firstTurn = Task { await controller.turnPage(towardLeft: true) }
        await fulfillment(of: [firstStarted], timeout: 10)
        XCTAssertEqual(controller.view.subviews.count, 2)

        controller.onPageTurnEnded = { [weak controller] in
            guard let controller else { return }
            XCTAssertFalse(controller.isTurningPage)
            XCTAssertFalse(controller.beginPageTurn(translation: CGPoint(x: -30, y: 0)))
            XCTAssertFalse(controller.view.isUserInteractionEnabled)
        }
        controller.replaceChild(with: replacement)
        XCTAssertNotNil(replacement.view.snapshotView(afterScreenUpdates: true))
        XCTAssertEqual(delegate.cancellations, [true])
        XCTAssertFalse(controller.isTurningPage)
        XCTAssertTrue(controller.view.isUserInteractionEnabled)
        XCTAssertEqual(controller.view.subviews, [replacement.view])
        XCTAssertEqual(original.view.transform, .identity)

        let nextStarted = expectation(description: "Replacement turn reached navigation")
        let (nextGate, releaseNext) = AsyncStream<Void>.makeStream()
        defer { releaseNext.finish() }
        delegate.onMove = {
            nextStarted.fulfill()
            for await _ in nextGate { break }
            return true
        }
        let nextTurn = Task { await controller.turnPage(towardLeft: true) }
        await fulfillment(of: [nextStarted], timeout: 10)
        let nextSubviews = controller.view.subviews
        XCTAssertEqual(nextSubviews.count, 2)
        releaseFirst.finish()
        await firstTurn.value
        XCTAssertEqual(controller.view.subviews, nextSubviews)
        XCTAssertTrue(controller.isTurningPage)
        XCTAssertFalse(controller.view.isUserInteractionEnabled)
        XCTAssertTrue(delegate.outcomes.isEmpty)

        releaseNext.finish()
        await nextTurn.value
        XCTAssertEqual(delegate.outcomes.count, 1)
        guard case .settled? = delegate.outcomes.first else {
            return XCTFail("The replacement turn did not settle")
        }
        XCTAssertFalse(controller.isTurningPage)
        XCTAssertTrue(controller.view.isUserInteractionEnabled)
        XCTAssertEqual(controller.view.subviews, [replacement.view])
        XCTAssertEqual(replacement.view.transform, .identity)
    }

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
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
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
        await session.foreground()
        XCTAssertTrue(session.isRestoring)
        XCTAssertFalse(session.container.view.isUserInteractionEnabled)

        let restored = expectChange("Visible reader restored the interrupted turn's origin") { _ = session.isRestoring }
        session.container.beginAppearanceTransition(true, animated: false)
        session.container.endAppearanceTransition()
        await fulfillment(of: [restored], timeout: 10)

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

    func testEPUBPageCurlReversesAndCancelsBeforeCommittingAcrossChapters() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "This regression inspects the interactive curl.")
        let store = try library()
        try store.updateReaderSettings { $0.pageTurnStyle = .curl }
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let container = session.container
        let window = present(container)
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        await session.go(try XCTUnwrap(session.contents.first { $0.title == "Second" }))
        let origin = try XCTUnwrap(store.book(book.id)?.position)
        func savedChapter() throws -> String {
            let json = try XCTUnwrap(store.book(book.id)?.position?.locatorJSON)
            return try XCTUnwrap(Locator(jsonString: json)).href.string
        }
        XCTAssertTrue(try savedChapter().hasSuffix("second.xhtml"))

        var saves: [ReadingPosition] = []
        let subscription = store.$books.dropFirst().sink { books in
            if let position = books.first(where: { $0.id == book.id })?.position { saves.append(position) }
        }
        defer { subscription.cancel() }

        func drag(_ fraction: CGFloat) -> CGPoint { CGPoint(x: container.view.bounds.width * fraction, y: 0) }
        func settle() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while container.isTurningPage && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(container.isTurningPage)
            XCTAssertNil(session.error)
        }

        XCTAssertTrue(container.beginPageTurn(translation: drag(-0.4)))
        container.updatePageTurn(translation: drag(-0.4))
        let curl = try XCTUnwrap(container.view.subviews.compactMap { $0 as? PageCurlView }.first)
        let content = try XCTUnwrap(container.children.first?.view)
        func revealedChapter() async throws -> String {
            let deadline = ContinuousClock.now + .seconds(3)
            while curl.progress == 0 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(16))
            }
            XCTAssertGreaterThan(curl.progress, 0)
            let webView = try XCTUnwrap(ReadiumPageTurnSurface.presentedWebView(in: content, viewport: container.view))
            let href = try await webView.evaluateJavaScript("window.readium.link.href")
            return try XCTUnwrap(href as? String)
        }
        let nextChapter = try await revealedChapter()
        XCTAssertTrue(nextChapter.hasSuffix("image.xhtml"))
        container.updatePageTurn(translation: drag(0.4))
        let previousChapter = try await revealedChapter()
        XCTAssertTrue(previousChapter.hasSuffix("first.xhtml"))
        XCTAssertEqual(store.book(book.id)?.position, origin)
        container.finishPageTurn(translation: drag(0.17), velocity: CGPoint(x: -450, y: 0))
        try await settle()
        XCTAssertNil(curl.superview)
        XCTAssertEqual(store.book(book.id)?.position, origin)
        XCTAssertTrue(saves.isEmpty)

        for (index, direction) in [1.0, -1.0, 1.0].enumerated() {
            let translation = drag(direction * 0.2)
            XCTAssertTrue(container.beginPageTurn(translation: translation))
            container.finishPageTurn(translation: translation, velocity: CGPoint(x: direction * 900, y: 0))
            try await settle()
            let chapter = direction > 0 ? "first.xhtml" : "second.xhtml"
            XCTAssertTrue(try savedChapter().hasSuffix(chapter))
            XCTAssertEqual(saves.count, index + 1)
        }
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

@MainActor private final class SuspendedTurnDelegate: ReaderPageTurnDelegate {
    var onMove: () async -> Bool = { false }
    private(set) var outcomes: [PageTurnOutcome] = []
    private(set) var cancellations: [Bool] = []

    func canBeginPageTurn(isGesture: Bool) -> Bool { true }
    func pageTurnWillBegin() {}
    func movePage(towardLeft: Bool) async throws -> Bool { await onMove() }
    func pageTurnDidFinish(_ outcome: PageTurnOutcome) async { outcomes.append(outcome) }
    func pageTurnWasCancelled(needsRestoration: Bool) { cancellations.append(needsRestoration) }
}
