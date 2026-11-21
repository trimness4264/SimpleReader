import XCTest
import PDFKit
import ReadiumShared
import ReadiumNavigator
import UIKit
@testable import SimpleReader

@MainActor final class ReadingPositionTests: XCTestCase {
    func testUnicodeXPointersMatchCREngine() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "xpointer-unicode", withExtension: "epub", subdirectory: "Fixtures"))
        let readium = ReadiumService()
        let publication = try await readium.open(file)
        let spine = try await readium.spine(file)
        let positions = await EPUBReadingPosition(publication: publication, spine: spine)

        // KOReader v2026.07.1, CREngine DOM 20240114. See Scripts/dump_crengine_xpointers.lua.
        let cases: [(id: String, word: String, path: String, start: Int, end: Int)] = [
            ("normal", "😀", "p[1]", 3, 4),
            ("normal", "𠮷", "p[1]", 5, 6),
            ("normal", "e\u{301}", "p[1]", 7, 9),
            ("normal", "afterNormal", "p[1]", 10, 21),
            ("preformatted", "afterPreformatted", "pre", 12, 29),
            ("inline-code", "afterCode", "p[2]/code", 10, 19),
        ]
        for layout in [ReadingLayout.paginated, .scroll] {
            try await withEPUBReader(publication: publication, spine: spine, layout: layout) { reader, navigator in
                if layout == .paginated {
                    let href = try XCTUnwrap(reader.currentLocation?.href.string)
                    _ = try await navigator.evaluatePositionJavaScript("""
                        document.getElementById('preformatted').style.breakBefore = 'column';
                        true;
                        """, in: href)
                }
                for sample in cases {
                    let path = "/body/DocFragment/body/\(sample.path)/text()"
                    let pointers = ["\(path).\(sample.start)", "\(path).\(sample.end)"]
                    let targets = try pointers.map(positions.target(for:))
                    let resource = targets[0].resource.href
                    let paths = String(decoding: try JSONEncoder().encode(targets.map(\.path)), as: UTF8.self)
                    let page = try await reader.move(to: .checkpoint(nil, pointer: pointers[0]), isCurrent: { true })
                    let location = try XCTUnwrap(page?.locator ?? reader.currentLocation)
                    XCTAssertEqual(location.href.string, resource)
                    if layout == .paginated, sample.id == "preformatted" {
                        XCTAssertGreaterThan(location.locations.progression ?? 0, 0)
                        XCTAssertEqual(page?.position.xpointer, "/body/DocFragment/body/pre/text().0")
                    }

                    let result = try await navigator.evaluatePositionJavaScript("""
                        (() => {
                          const bridge = window.SimpleReaderBridge;
                          const word = \(try EPUBPositionBridge.quoted(sample.word));
                          const node = document.getElementById(\(try EPUBPositionBridge.quoted(sample.id))).firstChild;
                          const start = node.data.indexOf(word);
                          if (start < 0) throw Error('Missing CREngine sample text: ' + word);
                          const expected = [start, start + word.length];
                          const resolved = \(paths).map(path => {
                            const anchor = bridge.resolve(path);
                            const resolvedNode = document.querySelector(anchor.cssSelector).childNodes[anchor.textNodeIndex];
                            return anchor.kind === 'text' && resolvedNode === node ? anchor.textOffset : null;
                          });
                          return {expected, resolved, paths: expected.map(offset => bridge.fromPoint(node, offset))};
                        })();
                        """, in: resource)
                    let values = try XCTUnwrap(result as? [String: Any])
                    let expected = try XCTUnwrap(values["expected"] as? [Int])
                    let captured = try XCTUnwrap(values["paths"] as? [String]).compactMap { positions.pointer(path: $0, href: resource) }
                    XCTAssertEqual(values["resolved"] as? [Int], expected, "\(layout) resolves \(pointers)")
                    XCTAssertEqual(captured, pointers, "\(layout) encodes \(sample.word) in \(sample.path)")
                    if layout == .scroll {
                        XCTAssertEqual(location.locations.otherLocations["continuousTextOffset"] as? Int, expected.first)
                    }
                }
            }
        }
    }

    func testRestoringPointerSurvivesChapterAndFontChanges() async throws {
        let readium = ReadiumService()
        let file = try epubFile()
        let publication = try await readium.open(file)
        let spine = try await readium.spine(file)
        let positions = await EPUBReadingPosition(publication: publication, spine: spine)
        let pointer = "/body/DocFragment[2]/body/p/text().0"

        try await withEPUBReader(publication: publication, spine: spine, layout: .scroll) { reader, navigator in
            let controller = try XCTUnwrap(navigator as? ContinuousEPUBController)
            try await reader.move(to: .checkpoint(nil, pointer: pointer), isCurrent: { true })
            let locator = try XCTUnwrap(reader.currentLocation)
            let captured = try await positions.capture(locator, in: navigator)
            controller.updateScrollInsets(UIEdgeInsets(top: 64, left: 0, bottom: 42, right: 0))
            let insetPointer = try await positions.capture(try XCTUnwrap(navigator.currentLocation), in: navigator)
            XCTAssertEqual(insetPointer, captured)
            let first = try XCTUnwrap(publication.readingOrder.first)
            try await reader.move(to: .link(first), isCurrent: { true })
            var settings = ReaderSettings()
            settings.fontSize = 180
            controller.updateSettings(settings)
            try await reader.move(to: .checkpoint(locator, pointer: captured), isCurrent: { true })

            XCTAssertEqual(navigator.currentLocation?.href.string, "second.xhtml")
            let restored = try await positions.capture(try XCTUnwrap(navigator.currentLocation), in: navigator)
            XCTAssertEqual(restored, captured)
        }
    }

    func testImageOnlyChapterProducesARestorableElementAnchor() async throws {
        let readium = ReadiumService()
        let file = try epubFile()
        let publication = try await readium.open(file)
        let spine = try await readium.spine(file)
        let positions = await EPUBReadingPosition(publication: publication, spine: spine)
        let pointer = "/body/DocFragment[3]/body/svg"

        for layout in [ReadingLayout.paginated, .scroll] {
            try await withEPUBReader(publication: publication, spine: spine, layout: layout) { reader, navigator in
                // CREngine also expresses media starts as element offsets without a text node.
                let page = try await reader.move(to: .checkpoint(nil, pointer: pointer + ".0"), isCurrent: { true })
                let locator = try XCTUnwrap(page?.locator ?? reader.currentLocation)
                let captured = try await positions.capture(locator, in: navigator)
                XCTAssertEqual(captured, pointer, "\(layout)")
                XCTAssertEqual(locator.href.string, "image.xhtml")
                XCTAssertNil(locator.locations.otherLocations["continuousTextNodeIndex"])
            }
        }
    }

    func testSupersededRestorationDoesNotMoveReader() async throws {
        let readium = ReadiumService()
        let file = try epubFile()
        let publication = try await readium.open(file)
        let spine = try await readium.spine(file)
        try await withEPUBReader(publication: publication, spine: spine, layout: .scroll) { reader, navigator in
            let original = navigator.currentLocation?.href.string
            do {
                try await reader.move(to: .checkpoint(nil, pointer: "/body/DocFragment[2]/body/p/text().0"), isCurrent: { false })
                XCTFail("A superseded restoration must be cancelled")
            } catch is CancellationError {} catch { XCTFail("Expected cancellation, received \(error)") }
            XCTAssertEqual(navigator.currentLocation?.href.string, original)
        }
    }

    func testContinuousEPUBReopensWhenSavedXPointerNoLongerResolves() async throws {
        let file = try epubFile()
        let readium = ReadiumService()
        let publication = try await readium.open(file)
        let spine = try await readium.spine(file)
        let saved = ReadingPosition(progression: 0.5, xpointer: "/body/DocFragment[2]/body/missing", updatedAt: Date())

        try await withEPUBReader(publication: publication, spine: spine, layout: .scroll, restoring: saved) { reader, _ in
            XCTAssertEqual(reader.currentLocation?.href.string, spine.first)
        }
    }

    private func withEPUBReader(publication: Publication, spine: [String], layout: ReadingLayout,
                                restoring saved: ReadingPosition? = nil,
                                body: (EPUBReader, EPUBReadingNavigator) async throws -> Void) async throws {
        var settings = ReaderSettings()
        settings.layout = layout
        let reader = try await EPUBReader(publication: publication, spine: spine, configuration: {
            .init(settings: settings, twoPages: false, systemIsDark: false)
        }, locator: nil)
        let container = ReaderContainerController()
        let window = present(container)
        defer { reader.close(); window.isHidden = true }
        reader.install(in: container)
        let initial = try await reader.initialSnapshot(restoring: saved, isCurrent: { true })
        _ = try XCTUnwrap(initial)
        try await body(reader, try XCTUnwrap(container.children.first as? EPUBReadingNavigator))
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

    func testPaginatedJumpRejectsMissingAnchorAndKeepsReadingPosition() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        let initial = try XCTUnwrap(store.book(book.id)?.position)
        var link = try XCTUnwrap(session.contents.dropFirst().first?.link)
        link.href += "#missing-anchor"

        await session.go(ContentsItem(title: "Missing anchor", link: link, pdfPage: nil))

        XCTAssertNotNil(session.error)
        XCTAssertEqual(store.book(book.id)?.position, initial)
        XCTAssertFalse(session.canReturnToPreviousPosition)
        XCTAssertFalse(session.isNavigating)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)

        await session.jump(toProgression: 1)
        XCTAssertTrue(session.canReturnToPreviousPosition)
        XCTAssertEqual(store.book(book.id)?.position?.xpointer, "/body/DocFragment[3]/body/svg")
        await session.close()
    }

    func testOlderRemoteResponseCannotReplaceANewPaginatedJump() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        server.remote = RemoteProgress(progress: "/body/DocFragment[2]/body/p/text().0", percentage: 0.5,
            timestamp: 200, device_id: "other")

        let readStarted = expectation(description: "Remote response waiting")
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        server.onRead = {
            readStarted.fulfill()
            for await _ in gate { break }
        }
        let synchronize = Task { await session.synchronize() }
        await fulfillment(of: [readStarted], timeout: 10)
        await session.jump(toProgression: 1)
        let jumped = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertEqual(jumped.xpointer, "/body/DocFragment[3]/body/svg")
        release.finish()
        await synchronize.value

        XCTAssertEqual(store.book(book.id)?.position, jumped)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        XCTAssertNil(session.prompt)
        XCTAssertTrue(session.container.view.isUserInteractionEnabled)
        server.onRead = nil
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

    func testForegroundKeepsReadingPositionWhileBackgroundUploadFinishes() async throws {
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
        // The background check reads the server before and after uploading.
        let expectedBackgroundReads = 2
        var reads = 0
        server.onRead = { [weak server] in
            reads += 1
            if reads > expectedBackgroundReads {
                server?.remote = RemoteProgress(progress: "5", percentage: 1, timestamp: 201, device_id: "other")
            }
        }
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

        XCTAssertEqual(reads, expectedBackgroundReads)
        XCTAssertEqual(session.currentPDFPage, 2)
        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 1)
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        await session.close()
    }

    func testOpeningInBackgroundDoesNotApplyRemotePositionOnForeground() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        let server = ProgressServer()
        server.remote = RemoteProgress(progress: "5", percentage: 1, timestamp: 200, device_id: "other")
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }

        await session.background()
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        await session.foreground()

        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        await session.synchronize()
        XCTAssertEqual(session.currentPDFPage, 5)
        await session.close()
    }

    func testTransientBackgroundResizeKeepsExactEPUBScrollOffset() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: epubFile())
        var settings = store.settings
        settings.reader.layout = .scroll
        try store.saveSettings(settings)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let controller = session.container
        let window = present(controller)
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader not ready")
        let navigator = try XCTUnwrap(controller.children.first as? ContinuousEPUBController)
        let originalSize = controller.view.bounds.size
        let originalInsets = navigator.scrollView.contentInset
        let scrollOffset: CGFloat = 240
        navigator.scrollView.setContentOffset(CGPoint(x: 0, y: scrollOffset), animated: false)
        await session.background()

        // The app switcher can temporarily report a different orientation.
        controller.view.frame.size = CGSize(width: originalSize.height, height: originalSize.width)
        session.updateScrollInsets(UIEdgeInsets(top: 24, left: 0, bottom: 40, right: 0))
        controller.view.layoutIfNeeded()
        XCTAssertNotEqual(controller.view.bounds.size, originalSize)
        XCTAssertEqual(navigator.scrollView.bounds.size, originalSize)
        XCTAssertEqual(navigator.scrollView.contentInset, originalInsets)
        controller.view.frame.size = originalSize
        session.updateScrollInsets(nil)
        controller.view.layoutIfNeeded()
        XCTAssertFalse(session.isRestoring)

        await session.foreground()
        XCTAssertEqual(navigator.scrollView.contentOffset.y, scrollOffset, accuracy: 0.5)
        XCTAssertFalse(session.isRestoring)
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

    func testRespondingToStaleOfferDoesNotRefreshProgressUntilManualSync() async throws {
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
        XCTAssertNil(session.prompt)

        await session.synchronize()
        let currentOffer = try XCTUnwrap(session.prompt)
        XCTAssertEqual(currentOffer.remote.fingerprint, server.remote?.fingerprint)

        await session.background()
        await session.respond(to: currentOffer, with: .uploadLocal)
        XCTAssertEqual(server.remote?.progress, "2")
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        var checked = false
        server.onRead = { checked = true }
        await session.foreground()
        XCTAssertFalse(checked)
        await session.close()
    }

    func testMovingWhileAConflictIsOpenInvalidatesItsUploadAction() async throws {
        let store = try library()
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: pdfFile(in: temporaryDirectory()))
        let server = ProgressServer()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
        let window = present(session.container)
        defer { window.isHidden = true }
        await session.load()
        let firstJump = await session.jump(toPage: 2)
        XCTAssertTrue(firstJump)
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        server.remote = RemoteProgress(progress: "5", percentage: 1, timestamp: 200, device_id: "other")
        await session.synchronize()
        let oldOffer = try XCTUnwrap(session.prompt)

        let nextJump = await session.jump(toPage: 3)
        XCTAssertTrue(nextJump)
        await session.respond(to: oldOffer, with: .uploadLocal)

        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 2)
        XCTAssertEqual(store.book(book.id)?.pendingSync, true)
        XCTAssertNil(session.prompt)

        await session.synchronize()
        let newOffer = try XCTUnwrap(session.prompt)
        await session.respond(to: newOffer, with: .uploadLocal)
        XCTAssertEqual(server.uploads.map(\.progress), ["3"])
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
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
        let originalNavigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
        let positions = await EPUBReadingPosition(publication: originalNavigator.publication, spine: spine)
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
            let visible = try await positions.capture(locator, in: navigator)
            XCTAssertEqual(visible, saved.xpointer)
            XCTAssertEqual(session.contents.map(\.id), contentsIDs)
            XCTAssertTrue(session.canReturnToPreviousPosition)
        }

        let previousNavigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
        try session.saveReaderSettings { $0.fontSize = 190 }
        XCTAssertTrue(session.isRestoring)
        let fontRestored = expectChange("Paginated font change restored") { _ = session.isRestoring }
        await fulfillment(of: [fontRestored], timeout: 10)
        XCTAssertFalse(session.isRestoring)
        XCTAssertNil(session.recoveryError)

        let viewport = session.container.view!
        viewport.frame.size.width -= 60
        viewport.layoutIfNeeded()
        XCTAssertTrue(session.isRestoring)
        let sizeRestored = expectChange("Paginated width change restored") { _ = session.isRestoring }
        await fulfillment(of: [sizeRestored], timeout: 10)
        XCTAssertFalse(session.isRestoring)
        XCTAssertNil(session.recoveryError)
        XCTAssertTrue(previousNavigator === session.container.children.first)
        let resizedLocator = try XCTUnwrap(previousNavigator.currentLocation)
        let resizedPointer = try await positions.capture(resizedLocator, in: previousNavigator)
        XCTAssertEqual(resizedPointer, saved.xpointer)
        XCTAssertEqual(store.book(book.id)?.position, saved)

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
        let recoveredPointer = try await positions.capture(recoveredLocation, in: replacement)
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
