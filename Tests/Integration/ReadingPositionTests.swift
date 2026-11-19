import XCTest
import PDFKit
import ReadiumShared
import ReadiumNavigator
import UIKit
@testable import SimpleReader

@MainActor final class ReadingPositionTests: XCTestCase {
    func testRestoringPointerSurvivesChapterAndFontChanges() async throws {
        let readium = ReadiumService()
        let file = try epubFile()
        let publication = try await readium.open(file)
        let positions = await EPUBReadingPosition(publication: publication, spine: try await readium.spine(file))
        let navigator = ContinuousEPUBController(publication: publication, initialLocation: nil, settings: ReaderSettings())
        let window = present(navigator)
        defer { navigator.close(); window.isHidden = true }
        let initial = try await positions.initialPosition(in: navigator, updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertNotNil(initial)
        let pointer = "/body/DocFragment[2]/body/p/text().0"

        let locator = try await positions.go(toPointer: pointer, in: navigator, isCurrent: { true })
        let captured = try await positions.capture(locator, in: navigator)
        navigator.updateScrollInsets(UIEdgeInsets(top: 64, left: 0, bottom: 42, right: 0))
        let insetPointer = try await positions.capture(try XCTUnwrap(navigator.currentLocation), in: navigator)
        XCTAssertEqual(insetPointer, captured)
        let first = try XCTUnwrap(publication.readingOrder.first)
        try await positions.go(to: first, in: navigator, isCurrent: { true })
        var settings = ReaderSettings()
        settings.fontSize = 180
        navigator.updateSettings(settings)
        try await positions.restore(locator, pointer: captured, in: navigator, isCurrent: { true })

        XCTAssertEqual(navigator.currentLocation?.href.string, "second.xhtml")
        let restored = try await positions.capture(try XCTUnwrap(navigator.currentLocation), in: navigator)
        XCTAssertEqual(restored, captured)
    }

    func testImageOnlyChapterProducesARestorableElementAnchor() async throws {
        let readium = ReadiumService()
        let file = try epubFile()
        let publication = try await readium.open(file)
        let positions = await EPUBReadingPosition(publication: publication, spine: try await readium.spine(file))
        let navigator = ContinuousEPUBController(publication: publication, initialLocation: nil, settings: ReaderSettings())
        let window = present(navigator)
        defer { navigator.close(); window.isHidden = true }
        let initial = try await positions.initialPosition(in: navigator, updatedAt: Date())
        XCTAssertNotNil(initial)
        let pointer = "/body/DocFragment[3]/body/svg"

        let locator = try await positions.go(toPointer: pointer, in: navigator, isCurrent: { true })
        let captured = try await positions.capture(locator, in: navigator)

        XCTAssertEqual(captured, pointer)
        XCTAssertEqual(navigator.currentLocation?.href.string, "image.xhtml")
    }

    func testSupersededRestorationDoesNotMoveReader() async throws {
        let readium = ReadiumService()
        let file = try epubFile()
        let publication = try await readium.open(file)
        let positions = await EPUBReadingPosition(publication: publication, spine: try await readium.spine(file))
        let navigator = ContinuousEPUBController(publication: publication, initialLocation: nil, settings: ReaderSettings())
        let window = present(navigator)
        defer { navigator.close(); window.isHidden = true }
        let initial = try await positions.initialPosition(in: navigator, updatedAt: Date())
        XCTAssertNotNil(initial)
        let original = navigator.currentLocation?.href.string

        do {
            _ = try await positions.go(toPointer: "/body/DocFragment[2]/body/p/text().0", in: navigator, isCurrent: { false })
            XCTFail("A superseded restoration must be cancelled")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, received \(error)") }

        XCTAssertEqual(navigator.currentLocation?.href.string, original)
    }

    func testEarlierChapterRemeasurementPreservesTheReadableRange() throws {
        var layout = ContinuousEPUBLayout(chapterCount: 3)
        let viewport = ContinuousEPUBLayout.Viewport(size: CGSize(width: 430, height: 800), offset: 1_500,
            insets: UIEdgeInsets(top: 64, left: 0, bottom: 42, right: 0))
        let range = layout.readableRange(in: 1, viewport: viewport)

        let compensation = try XCTUnwrap(layout.measure(700, chapter: 0, in: viewport))
        let updated = ContinuousEPUBLayout.Viewport(size: viewport.size, offset: compensation.offset, insets: viewport.insets)

        XCTAssertEqual(layout.visibleChapter(in: updated), 1)
        XCTAssertEqual(layout.readableRange(in: 1, viewport: updated), range)
    }

    func testOpeningAndReopeningEPUBDoesNotCreatePendingUpload() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let sync = SyncCoordinator(store: store, http: HTTPClient())
        var savedPointer: String?
        for _ in 0..<2 {
            let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
            let window = present(session.container)
            await session.load()
            XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
            let position = try XCTUnwrap(store.book(book.id)?.position)
            XCTAssertNotNil(position.xpointer)
            if let savedPointer = savedPointer { XCTAssertEqual(position.xpointer, savedPointer) }
            savedPointer = position.xpointer
            await session.close()
            window.isHidden = true
            XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        }
    }

    func testBackgroundDuringContentsJumpRestoresItsOrigin() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        let initial = try XCTUnwrap(store.book(book.id)?.position)
        let target = try XCTUnwrap(session.contents.last)

        let began = expectChange("Contents jump began") { _ = session.isNavigating }
        let jump = Task { await session.go(target) }
        await fulfillment(of: [began], timeout: 10)
        XCTAssertTrue(session.isNavigating)
        await session.background()
        await jump.value
        XCTAssertTrue(session.isRestoring)
        XCTAssertFalse(session.container.view.isUserInteractionEnabled)
        await session.foreground()

        XCTAssertEqual(store.book(book.id)?.position, initial)
        XCTAssertFalse(session.isRestoring)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)
        await session.close()
    }

    func testOlderRemoteResponseCannotReplaceANewPageTurn() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        server.remote = RemoteProgress(progress: "5", percentage: 1, timestamp: 200, device_id: "other")
        server.onRead = {
            session.pageTurnWillBegin()
            session.pageTurnWasCancelled(needsRestoration: false)
            XCTAssertTrue(session.canBeginPageTurn(isGesture: false))
        }

        await session.synchronize()

        XCTAssertNil(session.prompt)
        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        server.onRead = nil
        await session.close()
    }

    func testForegroundCheckWaitsForBackgroundUpload() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        let jumped = await session.jump(toPage: 2)
        XCTAssertTrue(jumped)
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)

        let uploadStarted = expectation(description: "Background upload started")
        let (upload, releaseUpload) = AsyncStream<Void>.makeStream()
        defer { releaseUpload.finish() }
        var reads = 0
        server.onRead = { reads += 1 }
        server.onUpload = {
            uploadStarted.fulfill()
            for await _ in upload { break }
        }
        let background = Task { await session.background() }
        await fulfillment(of: [uploadStarted], timeout: 10)

        let foregroundReturned = expectation(description: "Reader resumed while upload was pending")
        let foreground = Task {
            await session.foreground()
            foregroundReturned.fulfill()
        }
        await fulfillment(of: [foregroundReturned], timeout: 10)
        XCTAssertEqual(reads, 1)
        releaseUpload.finish()
        await foreground.value
        await background.value

        // Background read, upload confirmation, and the deferred foreground check.
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(session.currentPDFPage, 2)
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        await session.close()
    }

    func testRemoteResponseCannotMoveHiddenReader() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        server.remote = RemoteProgress(progress: "5", percentage: 1, timestamp: 200, device_id: "other")
        server.onRead = {
            session.container.beginAppearanceTransition(false, animated: false)
            session.container.endAppearanceTransition()
        }

        await session.synchronize()

        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertNil(session.prompt)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)

        server.onRead = nil
        session.container.beginAppearanceTransition(true, animated: false)
        session.container.endAppearanceTransition()
        let pdfView = try XCTUnwrap(session.container.view.subviews.compactMap { $0 as? PDFView }.first)
        let interrupted = expectation(description: "Reader disappeared during the remote PDF move")
        interrupted.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard session.isNavigating, let page = pdfView.currentPage, pdfView.document?.index(for: page) == 4 else { return }
                session.container.beginAppearanceTransition(false, animated: false)
                session.container.endAppearanceTransition()
                session.container.beginAppearanceTransition(true, animated: false)
                session.container.endAppearanceTransition()
                interrupted.fulfill()
            }
        }
        await session.synchronize()
        NotificationCenter.default.removeObserver(observer)
        await fulfillment(of: [interrupted], timeout: 10)

        XCTAssertTrue(session.isRestoring)
        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 0)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)

        let restored = expectChange("Reader restored its origin on return") { _ = session.isRestoring }
        await fulfillment(of: [restored], timeout: 10)
        XCTAssertEqual(session.currentPDFPage, 1)
        await session.synchronize()

        XCTAssertEqual(session.currentPDFPage, 5)
        XCTAssertEqual(store.book(book.id)?.remoteBaseline, server.remote?.fingerprint)
        await session.close()
    }

    func testRespondingToStaleOfferResumesPendingForegroundCheck() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        let jumped = await session.jump(toPage: 2)
        XCTAssertTrue(jumped)
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        server.remote = RemoteProgress(progress: "5", percentage: 1, timestamp: 200, device_id: "other")
        await session.synchronize()
        let staleOffer = try XCTUnwrap(session.prompt)

        await session.background()
        await session.foreground()
        server.remote = RemoteProgress(progress: "4", percentage: 0.8, timestamp: 201, device_id: "other")
        await session.respond(to: staleOffer, with: .useServer)

        XCTAssertEqual(session.currentPDFPage, 2)
        let currentOffer = try XCTUnwrap(session.prompt)
        XCTAssertEqual(currentOffer.remote.fingerprint, server.remote?.fingerprint)

        await session.background()
        await session.respond(to: currentOffer, with: .uploadLocal)
        XCTAssertEqual(server.remote?.progress, "2")
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        var checked = false
        server.onRead = { checked = true }
        await session.foreground()
        XCTAssertTrue(checked)
        await session.close()
    }

    func testFailedRemotePDFJumpPreservesLocalPositionAndReturnHistory() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        let jumped = await session.jump(toPage: 3)
        XCTAssertTrue(jumped)
        let saved = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertTrue(session.canReturnToPreviousPosition)

        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        server.remote = RemoteProgress(progress: "99", percentage: 1, timestamp: 200, device_id: "other")
        await session.synchronize()
        let conflict = try XCTUnwrap(session.prompt)
        await session.respond(to: conflict, with: .useServer)

        XCTAssertNotNil(session.syncError)
        XCTAssertNil(session.prompt)
        XCTAssertFalse(session.isNavigating)
        XCTAssertEqual(session.currentPDFPage, 3)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        XCTAssertTrue(session.canReturnToPreviousPosition)

        await session.returnToPreviousPosition()
        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertFalse(session.canReturnToPreviousPosition)
        await session.close()
    }

    func testRendererIgnoresEventsFromReplacedAndClosedEPUBs() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        var settings = ReaderSettings()
        settings.layout = .paginated
        let renderer = ReaderRenderer(readium: readium) { settings }
        let window = present(renderer.container)
        defer { renderer.close(); window.isHidden = true }
        try await renderer.open(book, at: store.fileURL(book.filePath))

        var taps = 0
        renderer.onEvent = { event in
            if case .epub(.toggleControls, _) = event { taps += 1 }
        }
        let original = try XCTUnwrap(renderer.epub)
        let originalCallback = try XCTUnwrap(original.onEvent)
        originalCallback(.toggleControls)
        XCTAssertEqual(taps, 1)

        settings.layout = .scroll
        try renderer.updatePreferences(at: original.currentLocation)
        let replacement = try XCTUnwrap(renderer.epub)
        XCTAssertFalse(original === replacement)
        let replacementCallback = try XCTUnwrap(replacement.onEvent)
        originalCallback(.toggleControls)
        replacementCallback(.toggleControls)
        XCTAssertEqual(taps, 2)

        renderer.close()
        replacementCallback(.toggleControls)
        XCTAssertEqual(taps, 2)
    }

    func testEPUBModeChangesAndRecoveryRetryPreservePositionAndReturnHistory() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = present(session.container)
        window.windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window.makeKeyAndVisible()
        session.container.view.layoutIfNeeded()
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        let spine = try await readium.spine(store.fileURL(book.filePath))
        let initial = try XCTUnwrap(store.book(book.id)?.position?.xpointer)
        let contentsIDs = session.contents.map(\.id)
        await session.go(try XCTUnwrap(session.contents.dropFirst().first))
        let saved = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertNotEqual(saved.xpointer, initial)
        XCTAssertTrue(session.canReturnToPreviousPosition)

        for layout in [ReadingLayout.scroll, .paginated] {
            var settings = store.settings
            settings.reader.layout = layout
            settings.reader.fontSize = 160
            try store.saveSettings(settings)
            session.updatePreferences()
            let restored = expectChange("Reader mode restored") { _ = session.isRestoring }
            await fulfillment(of: [restored], timeout: 10)
            XCTAssertFalse(session.isRestoring)

            XCTAssertNil(session.recoveryError)
            XCTAssertEqual(session.canBeginPageTurn(isGesture: false), layout == .paginated)
            XCTAssertEqual(store.book(book.id)?.position, saved)
            let navigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
            let locator = try XCTUnwrap(navigator.currentLocation)
            let visible = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: spine)
            XCTAssertEqual(visible, saved.xpointer)
            XCTAssertEqual(session.contents.map(\.id), contentsIDs)
            XCTAssertTrue(session.canReturnToPreviousPosition)
        }

        let previousNavigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
        session.resignActive()
        await session.retryRecovery()
        XCTAssertTrue(session.isRestoring)
        XCTAssertTrue(previousNavigator === session.container.children.first)
        await session.foreground()
        if session.isRestoring {
            let restored = expectChange("Deferred EPUB retry finished") { _ = session.isRestoring }
            await fulfillment(of: [restored], timeout: 10)
        }
        let replacement = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
        let recoveredLocation = try XCTUnwrap(replacement.currentLocation)
        let recoveredPointer = try await EPUBPositionBridge.capture(navigator: replacement, locator: recoveredLocation, spine: spine)
        XCTAssertFalse(previousNavigator === replacement)
        XCTAssertFalse(session.isRestoring)
        XCTAssertNil(session.recoveryError)
        XCTAssertEqual(recoveredPointer, saved.xpointer)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertTrue(session.canReturnToPreviousPosition)

        await session.returnToPreviousPosition()
        XCTAssertEqual(store.book(book.id)?.position?.xpointer, initial)
        XCTAssertFalse(session.canReturnToPreviousPosition)
        XCTAssertNil(session.error)
        await session.close()
    }
}
