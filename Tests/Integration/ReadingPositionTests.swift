import XCTest
import ReadiumShared
import ReadiumNavigator
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
}
