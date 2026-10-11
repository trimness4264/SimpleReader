import XCTest
import UIKit
import SwiftUI
import PDFKit
import ReadiumShared
@testable import SimpleReader

@MainActor final class ReaderNavigationTests: XCTestCase {
    func testPDFPageInputRemainsEditableWhenKeyboardAppears() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).writePDF(to: file) { context in
            for page in 1...8 {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
            }
        }
        let store = try LibraryStore(root: root.appendingPathComponent("library"), inMemory: true)
        let readium = ReadiumService(), sync = SyncCoordinator(store: store, http: HTTPClient())
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ReaderView(session: session, store: store, sync: sync))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await settle(session)
        let viewport = session.container.view.bounds
        let position = store.book(book.id)?.position
        func attachScreenshot(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachScreenshot("PDF reader footer")
        let panel = UIHostingController(rootView: PDFPageJumpView(session: session))
        window.rootViewController?.present(panel, animated: true)
        try await Task.sleep(nanoseconds: 700_000_000)
        func fields(in view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
        }
        func tappableField() -> UITextField? {
            fields(in: panel.view).first { field in
                guard let fieldWindow = field.window else { return false }
                let point = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: fieldWindow)
                let target = fieldWindow.hitTest(point, with: nil)
                return target === field || target?.isDescendant(of: field) == true
            }
        }
        for _ in 0..<80 {
            if tappableField() != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let field = try XCTUnwrap(tappableField(), "Page input must have a visible, tappable text field")
        XCTAssertTrue(field.becomeFirstResponder())
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(field.isFirstResponder, "Opening the keyboard must not disable or remove the page input")
        XCTAssertTrue(field.isEnabled)
        XCTAssertEqual(field.text, "")
        field.insertText("6")
        XCTAssertEqual(field.text, "6")
        XCTAssertEqual(session.container.view.bounds, viewport, "The page input keyboard must not resize the PDF")
        XCTAssertEqual(store.book(book.id)?.position, position)
        XCTAssertFalse(session.isRestoring)
        attachScreenshot("PDF page input")
        field.sendActions(for: .editingDidEndOnExit)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(session.currentPDFPage, 6)
        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 5)
        field.resignFirstResponder()
        await session.close()
    }
    func testEPUBJumpAndReturnSurviveTypographyAndLayoutChanges() async throws {
        for layout in [ReadingLayout.paginated, .scroll] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try LibraryStore(root: root, inMemory: true)
            var settings = store.settings
            settings.reader.layout = layout
            try store.saveSettings(settings)
            let readium = ReadiumService()
            let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
            let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
            let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                        sync: SyncCoordinator(store: store, http: HTTPClient()))
            let window = try show(session)
            defer { window.isHidden = true }
            await session.load()
            try await settle(session)
            let originalNavigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
            let originalLocator = try XCTUnwrap(originalNavigator.currentLocation)
            let pointer = try await EPUBPositionBridge.capture(navigator: originalNavigator, locator: originalLocator)

            await session.jump(toProgression: 0.8)
            XCTAssertNil(session.error)
            XCTAssertGreaterThan(session.progression, 0.5)
            XCTAssertTrue(session.canReturnToPreviousPosition)
            XCTAssertNotNil(store.book(book.id)?.position?.xpointer)
            settings.reader.layout = layout == .scroll ? .paginated : .scroll
            settings.reader.fontSize = 150
            try store.saveSettings(settings)
            session.updatePreferences()
            try await settle(session)
            await session.returnToPreviousPosition()
            XCTAssertNil(session.error)
            XCTAssertFalse(session.canReturnToPreviousPosition)
            let navigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
            XCTAssertEqual(EPUBPositionBridge.normalize(navigator.currentLocation?.href.string ?? ""),
                           EPUBPositionBridge.normalize(originalLocator.href.string))
            try await assertVisible(pointer, in: navigator)

            let lastChapter = try XCTUnwrap(session.contents.last)
            await session.go(lastChapter)
            XCTAssertTrue(session.canReturnToPreviousPosition)
            await session.returnToPreviousPosition()
            XCTAssertFalse(session.canReturnToPreviousPosition)
            try await assertVisible(pointer, in: navigator)
            await session.close()
        }
    }

    func testPDFPageAndSliderJumpsValidateRangeAndReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = PDFDocument()
        for index in 0..<8 {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 800)).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil)
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        let file = root.appendingPathComponent("pages.pdf")
        XCTAssertTrue(document.write(to: file))
        let store = try LibraryStore(root: root.appendingPathComponent("library"), inMemory: true)
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = try show(session)
        defer { window.isHidden = true }
        await session.load()
        try await settle(session)
        XCTAssertEqual(session.pdfPageCount, 8)
        XCTAssertEqual(session.currentPDFPage, 1)
        await session.jump(toPage: 6)
        XCTAssertEqual(session.currentPDFPage, 6)
        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 5)
        let saved = store.book(book.id)?.position
        await session.jump(toPage: 9)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertTrue(session.canReturnToPreviousPosition)
        session.error = nil
        await session.returnToPreviousPosition()
        XCTAssertEqual(session.currentPDFPage, 1)
        XCTAssertFalse(session.canReturnToPreviousPosition)
        await session.jump(toProgression: 1)
        XCTAssertEqual(session.currentPDFPage, 8)
        await session.returnToPreviousPosition()
        XCTAssertEqual(session.currentPDFPage, 1)
        await session.close()
    }

    func testBackgroundDuringJumpKeepsOriginalSavedPosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        let readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let window = try show(session)
        defer { window.isHidden = true }
        await session.load()
        try await settle(session)
        let original = store.book(book.id)?.position
        let task = Task { await session.jump(toProgression: 0.8) }
        while !session.isNavigating { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        session.resignActive()
        await task.value
        await session.foreground()
        try await settle(session)
        XCTAssertEqual(store.book(book.id)?.position, original)
        XCTAssertFalse(session.isNavigating)
        XCTAssertFalse(session.canReturnToPreviousPosition)
        XCTAssertNil(session.recoveryError)
        await session.close()
    }

    private func show(_ session: ReaderSession) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = session.container
        window.makeKeyAndVisible()
        return window
    }
    private func settle(_ session: ReaderSession) async throws {
        for _ in 0..<150 {
            if session.ready && !session.isRestoring {
                try await Task.sleep(nanoseconds: 700_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Reader did not settle: \(session.recoveryError ?? "no error")")
    }
    private func assertVisible(_ pointer: String, in navigator: EPUBReadingNavigator) async throws {
        _ = try await navigator.evaluateJavaScript(try EPUBPositionBridge.source).get()
        let result = try await navigator.evaluateJavaScript("""
        (() => {
          const anchor=SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(pointer)));
          const element=document.querySelector(anchor.cssSelector);
          const node=element.childNodes[anchor.textNodeIndex] || element;
          const range=document.createRange();
          if(node.nodeType===Node.TEXT_NODE) {range.setStart(node,anchor.textOffset);range.setEnd(node,Math.min(node.length,anchor.textOffset+1));}
          else range.selectNode(node);
          const rect=range.getBoundingClientRect();
          const viewport=window.SimpleReaderViewport || {top:0,bottom:innerHeight};
          return rect.bottom>viewport.top && rect.top<viewport.bottom && rect.right>0 && rect.left<innerWidth;
        })();
        """).get() as? Bool
        XCTAssertEqual(result, true, "Returning should reveal the original text anchor")
    }
}
