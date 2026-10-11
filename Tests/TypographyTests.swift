import XCTest
import UIKit
import ReadiumShared
import ReadiumNavigator
@testable import SimpleReader

@MainActor final class TypographyTests: XCTestCase {
    func testLegacySettingsKeepReadableDefaultsAndPersistTypography() throws {
        var settings = try JSONDecoder().decode(ReaderSettings.self, from: Data(#"{"fontSize":140,"theme":"dark"}"#.utf8))
        XCTAssertEqual(settings.font, .serif)
        XCTAssertEqual(settings.lineHeight, 1.65)
        XCTAssertEqual(settings.pageMargins, 1)
        settings.font = .system; settings.lineHeight = 1.9; settings.pageMargins = 1.75
        let restored = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.font, .system)
        XCTAssertEqual(restored.lineHeight, 1.9)
        XCTAssertEqual(restored.pageMargins, 1.75)
        XCTAssertEqual(restored.fontSize, 140)
        XCTAssertEqual(restored.theme, "dark")
    }

    func testTypographyReflowsBothLayoutsWithoutMovingSavedAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for layout in [ReadingLayout.paginated, .scroll] {
            let store = try LibraryStore(root: root.appendingPathComponent(layout.rawValue), inMemory: true)
            var settings = store.settings; settings.reader.layout = layout; try store.saveSettings(settings)
            let readium = ReadiumService()
            let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
            let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
            let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                        sync: SyncCoordinator(store: store, http: HTTPClient()))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = session.container; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            await session.load()
            try await waitForReflow(session)
            if let continuous = session.container.children.first as? ContinuousEPUBController {
                continuous.scrollView.setContentOffset(CGPoint(x: 0, y: 360), animated: false)
            } else { await session.turn(forward: true) }
            try await Task.sleep(nanoseconds: 700_000_000)
            await session.flush()
            let navigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
            let position = try XCTUnwrap(store.book(book.id)?.position)
            let pointer = try XCTUnwrap(position.xpointer)
            let widthScript = "document.querySelector('p').getBoundingClientRect().width"
            let originalWidthValue = try await navigator.evaluateJavaScript(widthScript).get() as? Double
            let originalWidth = try XCTUnwrap(originalWidthValue)
            for margin in [1.25, 1.5, 1.75] {
                settings.reader.font = .system; settings.reader.lineHeight = 1.9; settings.reader.pageMargins = margin
                try store.saveSettings(settings); session.updatePreferences()
            }
            try await waitForReflow(session)
            XCTAssertNil(session.recoveryError)
            if let epub = navigator as? EPUBNavigatorViewController {
                XCTAssertEqual(epub.settings.fontFamily?.rawValue, "-apple-system")
                XCTAssertEqual(epub.settings.lineHeight, 1.9)
                XCTAssertEqual(epub.settings.pageMargins, 1.75)
            }
            _ = try await navigator.evaluateJavaScript("(() => {const s=document.createElement('style');s.textContent='p, p span {font-family:Georgia;line-height:1.1}';document.head.append(s);return true;})()").get()
            let font = try await navigator.evaluateJavaScript("getComputedStyle(document.querySelector('p')).fontFamily").get() as? String
            XCTAssertTrue(try XCTUnwrap(font).contains("-apple-system"))
            let lineRatio = try await navigator.evaluateJavaScript("(() => {const s=getComputedStyle(document.querySelector('p'));return parseFloat(s.lineHeight)/parseFloat(s.fontSize);})()").get() as? Double
            XCTAssertEqual(try XCTUnwrap(lineRatio), 1.9, accuracy: 0.02)
            let newWidthValue = try await navigator.evaluateJavaScript(widthScript).get() as? Double
            let newWidth = try XCTUnwrap(newWidthValue)
            XCTAssertLessThan(newWidth, originalWidth, "Larger margins must reduce the actual text width")
            _ = try await navigator.evaluateJavaScript(try EPUBPositionBridge.source).get()
            let visibleScript = """
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
            """
            let visible = try await navigator.evaluateJavaScript(visibleScript).get() as? Bool
            XCTAssertEqual(visible, true)
            await session.flush()
            XCTAssertEqual(store.book(book.id)?.position, position)
            await session.close()
        }
    }

    private func waitForReflow(_ session: ReaderSession) async throws {
        for _ in 0..<150 {
            if session.ready && !session.isRestoring { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Reader did not finish reflow: \(session.recoveryError ?? "no error")")
    }
}
