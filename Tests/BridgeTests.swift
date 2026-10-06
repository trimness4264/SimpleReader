import XCTest
import WebKit
import ReadiumShared
import ReadiumNavigator
@testable import SimpleReader

@MainActor final class BridgeTests: XCTestCase, WKNavigationDelegate {
    private var loaded: XCTestExpectation?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill() }
    func page(_ html: String) async -> WKWebView {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        view.navigationDelegate = self
        loaded = expectation(description: "HTML loaded")
        view.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [loaded!], timeout: 10)
        return view
    }
    func testDOMBridgeHandlesWhitespaceInlineNodesAndInjectedWrappers() async throws {
        let view = await page("<html><body><p>  中文 <em>nested</em>  after\n text.</p><p cfi-skip><span>wrapped</span></p><div cfi-inert>injected</div><pre>one  two</pre></body></html>")
        _ = try await view.evaluateJavaScript(EPUBPositionBridge.source)
        let first = try await view.evaluateJavaScript("SimpleReaderBridge.fromPoint(document.querySelector('p').lastChild, 4, 1, false)") as! String
        XCTAssertEqual(first, "/body/DocFragment[2]/body/p/text()[2].3")
        let resolved = try await view.evaluateJavaScript("SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(first)))") as! [String: Any]
        XCTAssertEqual(resolved["spine"] as? Int, 1)
        XCTAssertTrue((resolved["highlight"] as? String)?.hasPrefix("ter") == true)
        let wrapper = try await view.evaluateJavaScript("SimpleReaderBridge.fromPoint(document.querySelector('span').firstChild, 2, 0, false)") as! String
        XCTAssertEqual(wrapper, "/body/DocFragment[1]/body/span/text().2")
        let pre = try await view.evaluateJavaScript("SimpleReaderBridge.fromPoint(document.querySelector('pre').firstChild, 5, 0, true)") as! String
        XCTAssertEqual(pre, "/body/DocFragment/body/pre/text().5")
        do { _ = try await view.evaluateJavaScript("SimpleReaderBridge.resolve('/body/DocFragment/body/p/text()[9].0')"); XCTFail("Invalid pointer must fail") } catch {}
    }
    func testReadiumOpensFixtureAndMapsChapterIndex() async throws {
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let publication = try await ReadiumService().open(file)
        XCTAssertEqual(publication.readingOrder.count, 2)
        XCTAssertEqual(publication.metadata.title, "同步测试图书")
        XCTAssertEqual(try EPUBPositionBridge.spineIndex("/body/DocFragment[2]/body/p[3]/text().4"), 1)
        XCTAssertEqual(try EPUBPositionBridge.spineIndex("/body/DocFragment/body/p"), 0)
        XCTAssertThrowsError(try EPUBPositionBridge.spineIndex("/body/DocFragment[0]/body"))
        XCTAssertThrowsError(try EPUBPositionBridge.spineIndex("epubcfi(/6/2!)"))
    }

    func testRealKOReaderEngineOracle707WordsBothDirections() async throws {
        let root = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/Oracle")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("positions.json"))) as! [String: Any]
        let fragments = json["fragments"] as! [[String: Any]]
        var verified = 0
        for fragment in fragments {
            let index = fragment["index"] as! Int
            let words = fragment["words"] as! [[String: String]]
            if words.isEmpty { continue }
            let html = try String(contentsOf: root.appendingPathComponent("chapter-\(index).xhtml"))
            let view = await page(html)
            _ = try await view.evaluateJavaScript(EPUBPositionBridge.source)
            let wordsJSON = String(decoding: try JSONSerialization.data(withJSONObject: words), as: UTF8.self)
            let errors = try await view.evaluateJavaScript("""
                (() => {
                  const failures = [];
                  for (const word of \(wordsJSON)) {
                    try {
                      const a = SimpleReaderBridge.resolve(word.xp), b = SimpleReaderBridge.resolve(word.xp_end);
                      const na = document.querySelector(a.cssSelector).childNodes[a.textNodeIndex];
                      const nb = document.querySelector(b.cssSelector).childNodes[b.textNodeIndex];
                      const r = document.createRange(); r.setStart(na,a.textOffset); r.setEnd(nb,b.textOffset);
                      if (r.toString() !== word.text) failures.push(word.xp + ': expected ' + word.text + ', got ' + r.toString());
                      const start = SimpleReaderBridge.fromPoint(na,a.textOffset,\(index),false);
                      const end = SimpleReaderBridge.fromPoint(nb,b.textOffset,\(index),false);
                      if (start !== word.xp || end !== word.xp_end) failures.push('reverse: ' + start);
                    } catch(e) { failures.push(word.xp + ': ' + e.message); }
                  }
                  return failures;
                })()
                """) as! [String]
            XCTAssertTrue(errors.isEmpty, errors.prefix(8).joined(separator: "\n"))
            verified += words.count
        }
        XCTAssertEqual(verified, 707)
    }
    func testReadiumNativeNavigatorCapturesAndAcceptsXPointer() async throws {
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let publication = try await ReadiumService().open(file)
        let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: nil)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = navigator; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var pointer: String?
        for _ in 0..<50 {
            if let locator = navigator.currentLocation { do { pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator) } catch { print("Capture not ready: \(error)") } }
            if pointer != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(pointer, "Actual Readium viewport must expose a visible正文 position")
        let remote = "/body/DocFragment[2]/body/p[1]/text().2"
        let locator = try await EPUBPositionBridge.locator(pointer: remote, navigator: navigator)
        XCTAssertEqual(locator.href.string, publication.readingOrder[1].href)
        let moved = await navigator.go(to: locator)
        XCTAssertTrue(moved)
        let value = try await navigator.evaluateJavaScript("SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(remote)))").get() as! [String: Any]
        XCTAssertEqual(value["highlight"] as? String, "阅读位置：你好，世界。")
    }
    func testEmbeddedEPUBContainerRendersWithoutCreatingPendingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(session.ready)
        if store.book(book.id)?.position?.xpointer == nil, let nav = session.container.children.first as? EPUBNavigatorViewController {
            print("BRIDGE DIAGNOSTIC parent \(session.container.view.bounds) child \(nav.view.bounds) href \(nav.currentLocation?.href.string ?? "nil")")
            do { print("ORIGINAL SPINE", try await readium.spine(file)) } catch { print("SPINE ERROR", error) }
            do { print("DOM", try await nav.evaluateJavaScript("JSON.stringify({w:innerWidth,h:innerHeight,body:document.body.innerHTML.slice(0,300),rect:document.body.getBoundingClientRect().toJSON()})").get()) } catch { print("DOM ERROR",error) }
            if let loc = nav.currentLocation { do { print("CAPTURE",try await EPUBPositionBridge.capture(navigator: nav, locator: loc)) } catch { print("CAPTURE ERROR",error) } }
        }
        XCTAssertNotNil(store.book(book.id)?.position?.xpointer, "Embedded Readium must expose visible text")
        XCTAssertFalse(store.book(book.id)!.pendingSync, "Opening a new book is not a user edit")
        await session.turn(forward: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        XCTAssertGreaterThan(store.book(book.id)?.position?.progression ?? 0, 0, "Progress must advance within a small compressed chapter")
        XCTAssertTrue(store.book(book.id)!.pendingSync)
    }
    func testOpeningAndRestoringPDFDoesNotCreatePendingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        let file = root.appendingPathComponent("sample.pdf")
        try renderer.writePDF(to: file) { context in
            for i in 1...3 { context.beginPage(); ("Page \(i)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)]) }
        }
        let readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let sync = SyncCoordinator(store: store, http: HTTPClient())
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready)
        await session.flush()
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        XCTAssertEqual(store.book(book.id)!.position?.pdfPage, 0)
        await session.turn(forward: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        await session.flush()
        XCTAssertTrue(store.book(book.id)!.pendingSync)
        XCTAssertEqual(store.book(book.id)!.position?.pdfPage, 1)
    }
    func testImportDeduplicatesRenamedBookAndRejectsHTML() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        let importer = BookImportService(store: store, readium: ReadiumService())
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let book = try await importer.importBook(from: file)
        let renamed = try await importer.importBook(from: file, filename: "renamed.epub")
        XCTAssertEqual(book.id, renamed.id); XCTAssertEqual(store.books.count, 1)
        let bad = root.appendingPathComponent("login.pdf"); try Data("<html>login</html>".utf8).write(to: bad)
        do { _ = try await importer.importBook(from: bad); XCTFail("HTML must not import") } catch {}
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.fileURL("Staging").path).count, 0)
    }
}
