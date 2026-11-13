import XCTest
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

        let jump = Task { await session.go(target) }
        await waitForValue(session.$isNavigating, description: "Contents jump began") { $0 }
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
        server.onRead = { session.pageTurnWillBegin() }

        await session.synchronize()

        XCTAssertNil(session.prompt)
        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        server.onRead = nil
        await session.close()
    }
}
