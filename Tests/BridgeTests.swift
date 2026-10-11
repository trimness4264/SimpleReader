import XCTest
import WebKit
import PDFKit
import SwiftUI
import ReadiumShared
import ReadiumNavigator
@testable import SimpleReader

private final class ReaderSyncStub: ProgressSyncClient {
    var remote: RemoteProgress?
    var failure: Error?
    var uploaded: [ReadingPosition] = []
    var onGet: (@MainActor () async -> Void)?
    func get(document: String) async throws -> RemoteProgress? {
        if let failure = failure { throw failure }
        await onGet?()
        return remote
    }
    func put(document: String, position: ReadingPosition, deviceID: String) async throws {
        if let failure = failure { throw failure }
        uploaded.append(position)
        remote = RemoteProgress(document: document, progress: position.pdfPage.map { String($0 + 1) } ?? position.xpointer, percentage: position.progression, timestamp: Double(uploaded.count), device_id: deviceID)
    }
}

@MainActor private final class MediaLayoutDelegate: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
        EPUBPositionBridge.installMediaLayout(in: controller)
    }
}

@MainActor final class BridgeTests: XCTestCase, WKNavigationDelegate {
    private func fixture(_ name: String) -> URL {
        Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }
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
    func testPaginatedImagesRemainWholeAcrossFontSizesAndRotation() async throws {
        let configuration = WKWebViewConfiguration()
        EPUBPositionBridge.installMediaLayout(in: configuration.userContentController)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        view.navigationDelegate = self
        loaded = expectation(description: "Paginated images loaded")
        // Intrinsic portrait/wide images, font-relative publisher sizing, and
        // inline SVG, all following text so they must move to the next column.
        view.loadHTMLString("""
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"/>
            <style>
              html { column-count:1; column-width:350px; column-gap:40px; column-fill:auto; height:100vh; width:100%; }
              body { margin:0; padding:20px; font-size:16px; line-height:1.5; }
              p { margin:0; }
              img, svg { width:40em; height:60em; }
            </style></head><body>
            <p style="height:150px">Before pictures</p>
            <img id="portrait" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='600' height='1200'%3E%3Crect width='600' height='1200' fill='red'/%3E%3C/svg%3E"/>
            <p>Between pictures</p>
            <figure style="margin:0"><img id="wide" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='1600' height='800'%3E%3Crect width='1600' height='800' fill='blue'/%3E%3C/svg%3E"/><figcaption>Caption</figcaption></figure>
            <svg id="vector" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 1200" width="600" height="1200"><rect width="600" height="1200" fill="green"/></svg>
            </body></html>
            """, baseURL: nil)
        await fulfillment(of: [loaded!], timeout: 10)
        _ = try await view.evaluateJavaScript(EPUBPositionBridge.source)
        for (width, height, columns) in [(390, 700, 1), (1024, 650, 2), (768, 1024, 1)] {
            view.frame.size = CGSize(width: width, height: height)
            view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            for size in [80, 100, 150, 200] {
                let failures = try await view.evaluateJavaScript("""
                    (() => {
                      document.documentElement.style.columnCount = '\(columns)';
                      document.documentElement.style.columnWidth = ((innerWidth - (\(columns) - 1) * 40) / \(columns)) + 'px';
                      document.body.style.fontSize = '\(Double(size) * 0.16)px';
                      SimpleReaderMediaLayout.refresh();
                      const failures = [];
                      const root = document.documentElement, body = document.body;
                      const usableWidth = (innerWidth - (\(columns) - 1) * 40) / \(columns) - 40;
                      for (const id of ['portrait','wide','vector']) {
                        const image = document.getElementById(id), rects = Array.from(image.getClientRects());
                        if (rects.length !== 1) failures.push(id + ': fragmented into ' + rects.length);
                        const r = rects[0];
                        if (!r || r.height <= 0 || r.width <= 0) { failures.push(id + ': empty'); continue; }
                        if (r.height > innerHeight - 40 || r.top < -1 || r.bottom > innerHeight + 1)
                          failures.push(id + ': crosses page vertically ' + JSON.stringify(r.toJSON()));
                        if (r.width > usableWidth + 1) failures.push(id + ': exceeds column width ' + r.width);
                        const expected = id === 'wide' ? 2 : 0.5;
                        if (Math.abs(r.width / r.height - expected) > 0.02) failures.push(id + ': aspect ratio changed');
                        const xp = SimpleReaderBridge.fromPoint(image,0,0,true);
                        if (document.querySelector(SimpleReaderBridge.resolve(xp).cssSelector) !== image)
                          failures.push(id + ': position changed');
                      }
                      return failures;
                    })()
                    """) as! [String]
                XCTAssertTrue(failures.isEmpty, "\(width)x\(height), \(columns) columns, \(size)%: " + failures.joined(separator: "; "))
            }
        }
        _ = try await view.evaluateJavaScript("document.documentElement.style.columnCount = 'auto'; document.documentElement.style.columnWidth = 'auto'; SimpleReaderMediaLayout.refresh()")
        let fixed = try await view.evaluateJavaScript("document.documentElement.hasAttribute('data-simple-reader-paginated')") as! Bool
        XCTAssertFalse(fixed, "Fixed layout and scrolling must retain publication image sizing")
    }
    func testReadiumMediaLayoutBeforePaginationAndAfterPreferencesChange() async throws {
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/image-only.epub")
        let publication = try await ReadiumService().open(file)
        let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: nil,
            config: .init(preferences: .init(columnCount: .one, fontSize: 0.8, publisherStyles: false)))
        let delegate = MediaLayoutDelegate()
        navigator.delegate = delegate
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        // A container supplies real iPad-sized WebView bounds even when this
        // regression runs on an iPhone simulator. Readium requires >= 960px
        // before applying the requested two-column preference.
        let host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(navigator); host.view.addSubview(navigator.view)
        navigator.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        navigator.didMove(toParent: host)
        defer { window.isHidden = true }
        var ready = false
        for _ in 0..<100 {
            if let value = try? await navigator.evaluateJavaScript("typeof SimpleReaderMediaLayout !== 'undefined' && document.documentElement.hasAttribute('data-simple-reader-paginated') && !!document.getElementById('first')?.complete").get(), value as? Bool == true {
                ready = true; break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(ready, "Document-start media hook must be installed in actual Readium")
        for columns in [ColumnCount.one, .two] {
            navigator.view.frame.size = columns == .one ? CGSize(width: 390, height: 700) : CGSize(width: 1024, height: 650)
            navigator.view.layoutIfNeeded()
            for fontSize in [0.8, 2.0] {
                navigator.submitPreferences(.init(columnCount: columns, fontSize: fontSize, publisherStyles: false))
                try await Task.sleep(nanoseconds: 400_000_000)
                let failures = try await navigator.evaluateJavaScript("""
                    (() => {
                      const failures = [];
                      if (!document.documentElement.hasAttribute('data-simple-reader-paginated')) failures.push('CSS columns not detected');
                      if (Number(getComputedStyle(document.documentElement).columnCount) !== \(columns == .one ? 1 : 2)) failures.push('Requested column count not applied');
                      for (const id of ['first','second','third']) {
                        const image = document.getElementById(id), rects = Array.from(image.getClientRects());
                        if (rects.length !== 1) failures.push(id + ': fragmented ' + rects.length);
                        const r = rects[0];
                        if (!r || r.width <= 0 || r.height <= 0) { failures.push(id + ': empty'); continue; }
                        if (r.top < -1 || r.bottom > innerHeight + 1) failures.push(id + ': exceeds actual page ' + JSON.stringify(r.toJSON()));
                        const expected = id === 'third' ? 0.75 : image.naturalWidth / image.naturalHeight;
                        if (Math.abs(r.width / r.height - expected) > 0.02) failures.push(id + ': aspect ratio changed');
                      }
                      return failures;
                    })()
                    """).get() as! [String]
                XCTAssertTrue(failures.isEmpty, "Readium \(columns), font \(fontSize): " + failures.joined(separator: "; "))
            }
        }
        // Restoring the right-hand picture in a two-page spread makes the
        // whole spread visible. Capture records its first visible picture,
        // while resolving the requested pointer still addresses the second.
        let second = "/body/DocFragment[1]/body/div[1]/img"
        let target = try await EPUBPositionBridge.locator(pointer: second, navigator: navigator)
        let moved = await navigator.go(to: target)
        XCTAssertTrue(moved)
        // The injected style lives in head and cannot change media DOM paths.
        let pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: XCTUnwrap(navigator.currentLocation))
        XCTAssertEqual(pointer, "/body/DocFragment[1]/body/img", "Two-page capture anchors the first visible media in reading order")
        let result = try await navigator.evaluateJavaScript("SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(pointer)))").get() as! [String: Any]
        XCTAssertEqual(result["highlight"] as? String, "")
        withExtendedLifetime(delegate) {}
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

    func testDOMBridgeCapturesMediaInReadingOrderAndBlankChapterAnchors() async throws {
        let view = await page("""
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"/></head>
            <body style="margin:0">
            <div cfi-inert style="height:20px">injected</div>
            <img style="display:none"/>
            <div cfi-skip><img id="first" style="display:block;width:300px;height:500px"/></div>
            <p>Caption after the image</p>
            <img id="second" style="display:block;width:300px;height:900px"/>
            <svg id="third" style="display:block;width:300px;height:500px"><rect width="300" height="500"/></svg>
            <div cfi-inert style="height:700px"></div>
            </body></html>
            """)
        _ = try await view.evaluateJavaScript(EPUBPositionBridge.source)
        let first = try await view.evaluateJavaScript("SimpleReaderBridge.capture(1,false)") as! String
        XCTAssertEqual(first, "/body/DocFragment[2]/body/img[2]")
        let second = try await view.evaluateJavaScript("window.scrollTo(0,document.getElementById('second').offsetTop + 100); SimpleReaderBridge.capture(1,false)") as! String
        XCTAssertEqual(second, "/body/DocFragment[2]/body/img[3]", "Partially visible images must anchor to the actual picture")
        let resolved = try await view.evaluateJavaScript("SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(second + ".0")))") as! [String: Any]
        let id = try await view.evaluateJavaScript("document.querySelector(\(try EPUBPositionBridge.quoted(resolved["cssSelector"] as! String))).id") as! String
        XCTAssertEqual(id, "second")
        XCTAssertEqual(resolved["highlight"] as? String, "")
        let svg = try await view.evaluateJavaScript("window.scrollTo(0,window.scrollY + document.getElementById('third').getBoundingClientRect().top); SimpleReaderBridge.capture(1,false)") as! String
        XCTAssertEqual(svg, "/body/DocFragment[2]/body/svg")
        let blank = try await view.evaluateJavaScript("document.body.replaceChildren(); window.scrollTo(0,0); SimpleReaderBridge.capture(0,true)") as! String
        XCTAssertEqual(blank, "/body/DocFragment/body")
        let body = try await view.evaluateJavaScript("SimpleReaderBridge.resolve('/body/DocFragment/body.0')") as! [String: Any]
        XCTAssertEqual(body["cssSelector"] as? String, "body")
        do { _ = try await view.evaluateJavaScript("SimpleReaderBridge.resolve('/body/DocFragment/body.9')"); XCTFail("Nonzero offsets without text must fail") } catch {}
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
        XCTAssertTrue(session.ready)
        XCTAssertNil(session.error)
        XCTAssertNotNil(store.book(book.id)?.position?.xpointer, "Embedded Readium must expose visible text")
        XCTAssertFalse(store.book(book.id)!.pendingSync, "Opening a new book is not a user edit")
        await session.turn(forward: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        XCTAssertGreaterThan(store.book(book.id)?.position?.progression ?? 0, 0, "Progress must advance within a small compressed chapter")
        XCTAssertTrue(store.book(book.id)!.pendingSync)
    }
    func testSyncResponseDuringEPUBTurnDoesNotRestoreOldPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let client = ReaderSyncStub()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { client }))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        let initialLocator = try XCTUnwrap(navigator.currentLocation)
        let initial = try XCTUnwrap(store.book(book.id)?.position)
        client.remote = RemoteProgress(progress: initial.xpointer, percentage: initial.progression, timestamp: 10, device_id: "other")
        var settings = store.settings; settings.sync.enabled = true; try store.saveSettings(settings)
        var turned: Locator?
        client.onGet = {
            // Native swipe navigation bypasses ReaderSession.turn(). Wait for its
            // location callback, then return the GET inside the save debounce.
            _ = await navigator.goForward()
            for _ in 0..<200 {
                if navigator.currentLocation?.jsonString != initialLocator.jsonString { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            turned = navigator.currentLocation
            XCTAssertNotEqual(turned?.jsonString, initialLocator.jsonString)
            XCTAssertFalse(store.book(book.id)!.pendingSync)
        }
        await session.synchronize()
        client.onGet = nil
        let location = try XCTUnwrap(turned)
        XCTAssertEqual(navigator.currentLocation?.jsonString, location.jsonString)
        XCTAssertNil(session.prompt)
        XCTAssertNil(store.book(book.id)?.remoteBaseline, "Deferred remote progress must not be acknowledged")
        await session.flush()
        XCTAssertTrue(store.book(book.id)!.pendingSync)
        XCTAssertGreaterThan(store.book(book.id)?.position?.progression ?? 0, initial.progression)
        XCTAssertTrue(client.uploaded.isEmpty)
        // A later explicit sync still offers the normal local/remote conflict.
        await session.synchronize(userInitiated: true)
        XCTAssertEqual(session.prompt?.kind, .conflict)
    }

    func testSyncResponseBeforeSwipeLocationCallbackDoesNotNavigate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let client = ReaderSyncStub()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { client }))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        let initial = try XCTUnwrap(navigator.currentLocation)
        client.remote = RemoteProgress(progress: "/body/DocFragment[2]/body", percentage: 0.8, timestamp: 10, device_id: "other")
        var settings = store.settings; settings.sync.enabled = true; try store.saveSettings(settings)
        client.onGet = {
            XCTAssertTrue(session.container.beginPageTurn(translation: CGPoint(x: -60, y: 0)))
        }
        await session.synchronize()
        XCTAssertEqual(navigator.currentLocation?.href, initial.href)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        XCTAssertNil(session.prompt)
    }

    func testLongHorizontalSwipeUsesOnePageAndOwnsNestedScrollGestures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = UIDevice.current.userInterfaceIdiom == .pad
            ? CGRect(x: 0, y: 0, width: 1000, height: 650)
            : CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        session.container.view.layoutIfNeeded()
        for _ in 0..<50 {
            if !session.isRestoring { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(session.isRestoring)
        XCTAssertNil(session.recoveryError)
        // Readium can publish the initial locator before enabling page navigation.
        try await Task.sleep(nanoseconds: 700_000_000)
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertEqual(navigator.settings.columnCount, .two) }
        let initial = try XCTUnwrap(navigator.currentLocation)
        await session.turn(forward: true)
        try await Task.sleep(nanoseconds: 700_000_000)
        let next = try XCTUnwrap(navigator.currentLocation)
        XCTAssertEqual(next.href, initial.href, "The fixture must have more than one page in its first chapter")
        XCTAssertGreaterThan(next.locations.progression ?? 0, initial.locations.progression ?? 0)
        await session.turn(forward: false)
        try await Task.sleep(nanoseconds: 700_000_000)

        let container = session.container
        let pan = try XCTUnwrap(container.view.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first)
        XCTAssertFalse(container.beginPageTurn(translation: CGPoint(x: 3, y: 60)), "Vertical gestures are not page turns")
        XCTAssertTrue(container.beginPageTurn(translation: CGPoint(x: -300, y: 3)))
        func visiblePage(in view: UIView) -> WKWebView? {
            guard !view.isHidden, view.alpha > 0.99 else { return nil }
            if let web = view as? WKWebView {
                let rect = web.convert(web.bounds, to: container.view).intersection(container.view.bounds)
                return rect.width > container.view.bounds.width / 2 ? web : nil
            }
            return view.subviews.lazy.compactMap { visiblePage(in: $0) }.first
        }
        let web = try XCTUnwrap(visiblePage(in: navigator.view))
        let originalOffset = web.scrollView.contentOffset
        let savedBeforeDrag = store.book(book.id)?.position
        container.updatePageTurn(translation: CGPoint(x: -web.bounds.width * 0.35, y: 0))
        XCTAssertEqual(web.scrollView.contentOffset.x, originalOffset.x + web.bounds.width * 0.35, accuracy: 1,
                       "Dragging must reveal the real adjacent page before release")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(store.book(book.id)?.position, savedBeforeDrag, "An uncommitted page preview must not be persisted")
        container.finishPageTurn(translation: CGPoint(x: -20, y: 0), velocity: CGPoint(x: 900, y: 0))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(web.scrollView.contentOffset.x, originalOffset.x, accuracy: 1,
                       "Reversing the drag returns to its original page")
        XCTAssertEqual(navigator.currentLocation?.locations.progression, initial.locations.progression)
        XCTAssertTrue(container.beginPageTurn(translation: CGPoint(x: -300, y: 3)))
        func checkScrollViews(_ view: UIView) -> Int {
            var count = 0
            if let scroll = view as? UIScrollView {
                XCTAssertFalse(container.gestureRecognizer(pan, shouldBeRequiredToFailBy: scroll.panGestureRecognizer), "The reader pan owns horizontal pagination")
                count += 1
            }
            return count + view.subviews.reduce(0) { $0 + checkScrollViews($1) }
        }
        XCTAssertGreaterThan(checkScrollViews(navigator.view), 1, "Both chapter and WebView pans use the same page-turn owner")
        container.finishPageTurn(translation: CGPoint(x: -1200, y: 0))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(navigator.currentLocation?.href, next.href)
        XCTAssertEqual(navigator.currentLocation?.locations.progression, next.locations.progression)
        XCTAssertFalse(container.isPageTurnGestureActive)
        container.finishPageTurn(translation: CGPoint(x: 1200, y: 0))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(navigator.currentLocation?.locations.progression, initial.locations.progression)
        XCTAssertEqual(navigator.view.transform, .identity)
        XCTAssertEqual(container.view.subviews.count, 1, "A completed turn must remove its old-page snapshot")
        await container.animatePageTurn(direction: 1) {
            container.cancelPageTransition()
            return false
        }
        XCTAssertEqual(navigator.currentLocation?.locations.progression, initial.locations.progression)
        XCTAssertEqual(navigator.view.transform, .identity)
        XCTAssertEqual(container.view.subviews.count, 1, "A cancelled turn must leave only the reader content")
    }

    func testPageTurnRecognizesQuickSwipeAndCancelsReversal() {
        let container = ReaderContainerController()
        container.loadViewIfNeeded()
        container.view.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        container.canTurnPage = { true }
        var turns: [Bool] = []
        container.onPageTurn = { turns.append($0) }

        XCTAssertTrue(container.beginPageTurn(translation: CGPoint(x: -10, y: 0)))
        container.finishPageTurn(translation: CGPoint(x: -10, y: 0), velocity: CGPoint(x: -700, y: 0))
        XCTAssertEqual(turns, [true], "A short, fast swipe advances one page")
        XCTAssertFalse(container.isPageTurnGestureActive)

        container.finishPageTurn(translation: CGPoint(x: -10, y: 0))
        XCTAssertEqual(turns, [true], "A short drag settles back without navigation")
        container.finishPageTurn(translation: CGPoint(x: -40, y: 0), velocity: CGPoint(x: 700, y: 0))
        XCTAssertEqual(turns, [true], "Reversing a drag must cancel instead of turning the opposite page")
        container.finishPageTurn(translation: CGPoint(x: 1000, y: 0))
        XCTAssertEqual(turns, [true, false], "Even a long drag navigates only once")
    }

    func testQuickSwipeSurvivesImmediateBackgroundAndChapterPreviewsCommitOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        session.container.view.layoutIfNeeded()
        for _ in 0..<50 {
            if !session.isRestoring { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let container = session.container
        var navigator = try XCTUnwrap(container.children.first as? EPUBNavigatorViewController)
        let initialPointer = store.book(book.id)?.position?.xpointer
        func waitForGesture() async throws {
            for _ in 0..<150 {
                if !container.isPageTurnGestureActive { return }
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            XCTFail("The page gesture must settle before another navigation")
        }
        XCTAssertTrue(container.beginPageTurn(translation: CGPoint(x: -12, y: 0)))
        container.updatePageTurn(translation: CGPoint(x: -12, y: 0))
        container.finishPageTurn(translation: CGPoint(x: -12, y: 0), velocity: CGPoint(x: -1200, y: 0))
        try await waitForGesture()
        let committed = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertNotEqual(committed.xpointer, initialPointer, "A quick swipe commits a new text anchor before becoming idle")
        XCTAssertGreaterThan(committed.progression, 0)
        // Do not wait for Readium's delayed location notification here.
        await session.background()
        await session.foreground()
        XCTAssertNil(session.recoveryError)
        navigator = try XCTUnwrap(container.children.first as? EPUBNavigatorViewController)
        let restored = try await EPUBPositionBridge.capture(navigator: navigator, locator: XCTUnwrap(navigator.currentLocation))
        XCTAssertEqual(restored, committed.xpointer, "Immediate backgrounding must keep the committed page's first text")

        let firstLink = navigator.publication.readingOrder[0]
        let firstLocation = await navigator.publication.locate(firstLink)
        let lastPage = try XCTUnwrap(firstLocation).copy(locations: { $0.progression = 0.99 })
        let reachedLastPage = await navigator.go(to: lastPage, options: .init(animated: false))
        XCTAssertTrue(reachedLastPage)
        try await container.waitForEPUBContent()
        try await Task.sleep(nanoseconds: 700_000_000)
        let lastHref = try XCTUnwrap(navigator.currentLocation?.href)
        let nextHref = navigator.publication.readingOrder[1].url()
        XCTAssertTrue(container.beginPageTurn(translation: CGPoint(x: -140, y: 0)))
        container.updatePageTurn(translation: CGPoint(x: -140, y: 0))
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(navigator.currentLocation?.href, lastHref, "A neighboring chapter preview cannot change the selected chapter")
        container.finishPageTurn(translation: CGPoint(x: -20, y: 0), velocity: CGPoint(x: 800, y: 0))
        try await waitForGesture()
        XCTAssertEqual(navigator.currentLocation?.href, lastHref)
        XCTAssertTrue(container.beginPageTurn(translation: CGPoint(x: -140, y: 0)))
        container.updatePageTurn(translation: CGPoint(x: -140, y: 0))
        container.finishPageTurn(translation: CGPoint(x: -140, y: 0), velocity: CGPoint(x: -900, y: 0))
        try await waitForGesture()
        for _ in 0..<60 {
            if navigator.currentLocation?.href == nextHref { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(navigator.currentLocation?.href, nextHref)
        XCTAssertLessThan(navigator.currentLocation?.locations.progression ?? 1, 0.1,
                          "Crossing the chapter boundary must land on its first page")
        var began = false
        for _ in 0..<60 {
            if container.beginPageTurn(translation: CGPoint(x: 140, y: 0)) { began = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(began)
        container.updatePageTurn(translation: CGPoint(x: 140, y: 0))
        container.finishPageTurn(translation: CGPoint(x: 140, y: 0), velocity: CGPoint(x: 900, y: 0))
        try await waitForGesture()
        for _ in 0..<60 {
            if navigator.currentLocation?.href == lastHref { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(navigator.currentLocation?.href, lastHref)
        XCTAssertGreaterThan(navigator.currentLocation?.locations.progression ?? 0, 0.5,
                             "Moving back across the boundary must land on the prior chapter's final page")
        await session.close()
    }

    func testCancellingActivePageAnimationRestoresContent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), container = ReaderContainerController()
        window.rootViewController = container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for usesPDF in [false, true] {
            let child = UIViewController()
            child.view.backgroundColor = .white
            container.replaceChild(with: child)
            let content: UIView
            if usesPDF {
                child.willMove(toParent: nil); child.view.removeFromSuperview(); child.removeFromParent()
                content = PDFView(frame: container.view.bounds)
                container.view.addSubview(content)
            } else {
                content = child.view
            }
            container.view.layoutIfNeeded()
            // A newly installed view needs a display frame before UIKit can snapshot it.
            try await Task.sleep(nanoseconds: 100_000_000)
            let turn = Task {
                await container.animatePageTurn(direction: 1) { true }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(container.view.subviews.count, 2, "The old page remains visible during the transition")
            container.cancelPageTransition()
            await turn.value
            XCTAssertEqual(content.transform, .identity)
            XCTAssertEqual(container.view.subviews.count, 1, "Cancelling must reveal the reader and release the suspended turn")
        }
    }

    func testBackgroundAndCloseDoNotApplyRemoteProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let client = ReaderSyncStub()
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { client }))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let initial = store.book(book.id)?.position
        client.remote = RemoteProgress(progress: "/body/DocFragment[2]/body/p", percentage: 0.8, timestamp: 10, device_id: "other")
        var settings = store.settings; settings.sync.enabled = true; try store.saveSettings(settings)
        // Backgrounding also invalidates an already outstanding foreground GET.
        client.onGet = { await session.background() }
        await session.synchronize()
        client.onGet = nil
        await session.background()
        await session.close()
        XCTAssertEqual(store.book(book.id)?.position, initial)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
        XCTAssertNil(session.prompt)
        XCTAssertTrue(client.uploaded.isEmpty)
    }

    func testEPUBLoadsAfterContainerAppearsWithoutCreatingPendingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Exercise embedding after the parent's appearance transition has finished.
        try await Task.sleep(nanoseconds: 300_000_000)
        await session.load()
        XCTAssertTrue(session.ready)
        XCTAssertNil(session.error)
        XCTAssertNotNil(store.book(book.id)?.position?.xpointer)
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        await session.close()
        XCTAssertFalse(store.book(book.id)!.pendingSync, "Closing an untouched book is not a user edit")
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
        let client = ReaderSyncStub()
        let sync = SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { client })
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
        await session.close()
        let saved = try XCTUnwrap(store.book(book.id)?.position)
        let reopened = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        reopened.container.view.frame = .zero
        let loading = Task { await reopened.load() }
        try await Task.sleep(nanoseconds: 500_000_000)
        window.rootViewController = reopened.container
        await loading.value
        XCTAssertEqual(reopened.currentPDFPage, 2)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertTrue(store.book(book.id)!.pendingSync)
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        await reopened.synchronize()
        XCTAssertEqual(client.uploaded, [saved])
        XCTAssertEqual(client.remote?.progress, "2")
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        XCTAssertNil(reopened.syncMessage)

        client.remote = RemoteProgress(document: sync.document(book), progress: "3", percentage: 1,
                                       timestamp: 10, device_id: "other-device")
        await reopened.synchronize()
        XCTAssertEqual(reopened.currentPDFPage, 3)
        XCTAssertEqual(store.book(book.id)?.position?.pdfPage, 2)
        XCTAssertEqual(store.book(book.id)?.remoteBaseline, client.remote?.fingerprint)
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        await reopened.close()
        let restoredRemote = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        window.rootViewController = restoredRemote.container
        await restoredRemote.load()
        XCTAssertEqual(restoredRemote.currentPDFPage, 3)
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        XCTAssertEqual(client.uploaded.count, 1)
        await restoredRemote.close()
    }
    func testImageOnlyEPUBLoadsSavesAndRestoresWithoutSyncAlerts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/image-only.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        var settings = store.settings; settings.sync.enabled = true; try store.saveSettings(settings)
        let client = ReaderSyncStub(); client.failure = URLError(.notConnectedToInternet)
        let sync = SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { client })
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene); window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let started = Date()
        await session.load()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Image pages must not retry text capture for ten seconds")
        XCTAssertTrue(session.ready)
        XCTAssertNil(session.error)
        XCTAssertNil(session.prompt)
        XCTAssertNotNil(session.syncMessage)
        XCTAssertNotNil(store.book(book.id)?.position?.locatorJSON)
        XCTAssertEqual(store.book(book.id)?.position?.xpointer, "/body/DocFragment[1]/body/img")
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        await session.go(try XCTUnwrap(session.contents.last))
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        let saved = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertTrue(saved.locatorJSON?.contains("blank.xhtml") == true)
        XCTAssertEqual(saved.xpointer, "/body/DocFragment[2]/body")
        XCTAssertTrue(store.book(book.id)!.pendingSync)
        await session.synchronize()
        await session.synchronize(userInitiated: true)
        XCTAssertNil(session.error, "Repeated sync failures must stay in the status bar")
        XCTAssertNil(session.prompt)
        await session.close()
        let restored = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        window.rootViewController = restored.container
        await restored.load()
        XCTAssertTrue(restored.ready)
        XCTAssertTrue(store.book(book.id)?.position?.locatorJSON?.contains("blank.xhtml") == true)
        XCTAssertEqual(store.book(book.id)?.position?.updatedAt, saved.updatedAt)
        XCTAssertNil(restored.error)
        client.failure = nil
        client.remote = RemoteProgress(progress: "epubcfi(/6/2!)", percentage: 0.2)
        await restored.synchronize()
        XCTAssertEqual(restored.prompt?.kind, .conflict)
        restored.prompt = nil
        // Simulate choosing the remote position from a conflict prompt.
        await restored.receive(try XCTUnwrap(client.remote))
        XCTAssertEqual(restored.prompt?.kind, .approximate)
        restored.prompt = nil
        var local = try XCTUnwrap(store.book(book.id)); local.pendingSync = false; try store.save(local)
        await restored.synchronize()
        XCTAssertNil(restored.prompt, "An unchanged failed remote position must not prompt again automatically")
        await restored.synchronize(userInitiated: true)
        XCTAssertEqual(restored.prompt?.kind, .approximate, "Manual sync can retry remote positioning")
        XCTAssertNil(restored.error)
    }
    func testImageOnlyEPUBUploadsAndRestoresSpecificImageAndSVG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/image-only.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        var settings = store.settings; settings.sync.enabled = true; try store.saveSettings(settings)
        let client = ReaderSyncStub()
        let sync = SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { client })
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        // This regression checks exact page-by-page media restoration. Give it
        // the same single-page viewport on iPhone and iPad; spread navigation
        // intentionally advances two pages and captures the first visible one.
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        XCTAssertTrue(session.ready)
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        let columns = try await navigator.evaluateJavaScript("Number(getComputedStyle(document.documentElement).columnCount)").get() as! Int
        XCTAssertEqual(columns, 1, "Specific-image navigation requires the explicit single-page test viewport")
        let second = "/body/DocFragment[1]/body/div[1]/img"
        await session.turn(forward: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        XCTAssertEqual(store.book(book.id)?.position?.xpointer, second)
        await session.synchronize()
        XCTAssertEqual(client.uploaded.last?.xpointer, second)
        XCTAssertFalse(store.book(book.id)!.pendingSync)
        XCTAssertNil(session.bridgeWarning)
        for pointer in ["/body/DocFragment[1]/body/img", second, "/body/DocFragment[1]/body/div[2]/svg", "/body/DocFragment[2]/body"] {
            client.remote = RemoteProgress(progress: pointer, percentage: 0, timestamp: Date().timeIntervalSince1970)
            await session.synchronize()
            XCTAssertNil(session.prompt)
            XCTAssertNil(session.syncMessage)
            let locator = try XCTUnwrap(navigator.currentLocation)
            let captured = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator)
            XCTAssertEqual(captured, pointer, "Remote media XPointer must land on the specified image or chapter")
            XCTAssertEqual(store.book(book.id)?.position?.xpointer, pointer)
            XCTAssertFalse(store.book(book.id)!.pendingSync)
        }
    }
    func testEPUBResizePreservesCheckpointWithoutCreatingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        for _ in 0..<4 {
            await session.turn(forward: true)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        var checkpoint = try XCTUnwrap(store.book(book.id))
        let saved = try XCTUnwrap(checkpoint.position)
        XCTAssertGreaterThan(saved.progression, 0)
        checkpoint.pendingSync = false; try store.save(checkpoint)
        for size in [CGSize(width: 1000, height: 650), CGSize(width: 390, height: 700)] {
            session.container.view.frame.size = size
            XCTAssertTrue(session.isRestoring, "Protect the reading position before the viewport changes")
            session.container.view.setNeedsLayout(); session.container.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await session.flush()
            XCTAssertEqual(store.book(book.id)?.position?.xpointer, saved.xpointer)
            XCTAssertEqual(store.book(book.id)?.position?.updatedAt, saved.updatedAt)
            XCTAssertFalse(try XCTUnwrap(store.book(book.id)).pendingSync, "A viewport change is not a reading edit")
            XCTAssertNil(session.error)
            XCTAssertNil(session.recoveryError)
            XCTAssertFalse(session.isRestoring)
            let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
            let visible = try await readingAnchorIsVisible(XCTUnwrap(saved.xpointer), in: navigator)
            XCTAssertEqual(visible, true, "The original reading anchor must remain visible after reflow")
        }
    }

    private func readingAnchorIsVisible(_ pointer: String, in navigator: EPUBReadingNavigator) async throws -> Bool {
        let result = try await navigator.evaluateJavaScript("""
            \(try EPUBPositionBridge.source)
            (() => {
                const target = SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(pointer)));
                const element = document.querySelector(target.cssSelector);
                const node = element.childNodes[target.textNodeIndex];
                const range = document.createRange();
                if (node && node.nodeType === Node.TEXT_NODE) {
                    range.setStart(node, target.textOffset);
                    range.setEnd(node, Math.min(node.length, target.textOffset + 1));
                } else { range.selectNode(element); }
                const viewport = window.SimpleReaderViewport || {top: 0, bottom: innerHeight};
                return Array.from(range.getClientRects()).some(rect =>
                    rect.right > 0 && rect.left < innerWidth && rect.bottom > viewport.top && rect.top < viewport.bottom);
            })()
            """).get()
        return result as? Bool == true
    }

    func testForegroundRestoresBlankEPUBWithoutChangingCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        await session.turn(forward: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        var checkpoint = try XCTUnwrap(store.book(book.id))
        checkpoint.pendingSync = false; try store.save(checkpoint)
        let saved = try XCTUnwrap(checkpoint.position)
        let original = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)

        session.resignActive()
        await session.foreground()
        XCTAssertTrue(session.container.children.first === original, "A brief interruption should retain the renderer")
        await session.background()
        _ = try await original.evaluateJavaScript("document.body.replaceChildren() ").get()
        await session.foreground()

        XCTAssertFalse(session.isRestoring)
        XCTAssertNil(session.recoveryError)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertFalse(try XCTUnwrap(store.book(book.id)).pendingSync)
        let restored = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        let visible = try await readingAnchorIsVisible(XCTUnwrap(saved.xpointer), in: restored)
        XCTAssertTrue(visible, "Returning to the foreground must render the saved paragraph without a page turn")
        await session.close()
    }

    func testCloseCancelsForegroundRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let saved = store.book(book.id)?.position
        let original = try XCTUnwrap(session.container.children.first)
        await session.background()
        let recovery = Task { await session.foreground() }
        await Task.yield()
        await session.close()
        await recovery.value
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(session.container.children.first === original)
        XCTAssertEqual(store.book(book.id)?.position, saved)
        XCTAssertFalse(try XCTUnwrap(store.book(book.id)).pendingSync)
    }

    func testForegroundRetainsTurnBeforeDebouncedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let initial = try XCTUnwrap(store.book(book.id)?.position)
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        await session.turn(forward: true)
        for _ in 0..<30 {
            if session.progression > initial.progression { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let location = try XCTUnwrap(navigator.currentLocation)
        let pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: location)
        XCTAssertEqual(store.book(book.id)?.position, initial, "The save debounce must still be pending")
        await session.background()
        await session.foreground()
        XCTAssertNil(session.recoveryError)
        let saved = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertGreaterThan(saved.progression, initial.progression)
        XCTAssertNotNil(saved.xpointer, "The last turn must remain usable for KOReader Sync")
        let restored = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        let visible = try await readingAnchorIsVisible(pointer, in: restored)
        XCTAssertTrue(visible)
        await session.close()
    }

    func testPDFResizeRetainsVisiblePageWithoutCreatingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let file = root.appendingPathComponent("rotation.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800))
        try renderer.writePDF(to: file) { context in
            for number in 1...6 {
                context.beginPage()
                ("Page \(number)" as NSString).draw(at: CGPoint(x: 40, y: 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        for _ in 0..<3 { await session.turn(forward: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await session.flush()
        var checkpoint = try XCTUnwrap(store.book(book.id))
        let saved = try XCTUnwrap(checkpoint.position)
        XCTAssertEqual(saved.pdfPage, 3)
        checkpoint.pendingSync = false; try store.save(checkpoint)
        let pdf = try XCTUnwrap(session.container.view.subviews.compactMap { $0 as? PDFView }.first)
        let page = try XCTUnwrap(pdf.document?.page(at: 3))
        for size in [CGSize(width: 1000, height: 650), CGSize(width: 390, height: 700)] {
            session.container.view.frame.size = size
            session.container.view.setNeedsLayout(); session.container.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await session.flush()
            XCTAssertTrue(pdf.visiblePages.contains(page), "Viewport \(size), visible pages: \(pdf.visiblePages.map { pdf.document!.index(for: $0) }), destination: \(String(describing: pdf.currentDestination))")
            XCTAssertEqual(store.book(book.id)?.position, saved)
            XCTAssertFalse(try XCTUnwrap(store.book(book.id)).pendingSync)
            XCTAssertFalse(session.isRestoring)
            XCTAssertNil(session.recoveryError)
        }
        await session.close()
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

    func testSharedImportRecoversInboxWithoutOpenURLEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        let inbox = root.appendingPathComponent("Documents/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let source = inbox.appendingPathComponent("中文 分享.EPUB")
        try FileManager.default.copyItem(at: Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub"), to: source)
        let imports = SharedBookImportCoordinator(importer: BookImportService(store: store, readium: ReadiumService()), inbox: inbox)
        let tasks = imports.recoverInbox()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(imports.pendingCount, 1)
        XCTAssertNil(imports.receive(source), "A simultaneous openURL callback must not import twice")
        for task in tasks { await task.value }
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.originalFilename, "中文 分享.EPUB")
        let book = try XCTUnwrap(store.books.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(book.filePath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(imports.receive(source), "A delayed callback for the consumed Inbox copy must be ignored")
        XCTAssertEqual(imports.pendingCount, 0)
        XCTAssertNotNil(imports.message)
        XCTAssertNil(imports.error)
        // Files can reuse an Inbox filename for a subsequent share in this session.
        try FileManager.default.copyItem(at: Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub"), to: source)
        let repeated = imports.recoverInbox()
        XCTAssertEqual(repeated.count, 1)
        for task in repeated { await task.value }
        XCTAssertEqual(store.books.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNil(imports.error)
    }

    func testSharedImportPreservesExternalFilesAndFailedInboxCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let imports = SharedBookImportCoordinator(importer: BookImportService(store: store, readium: ReadiumService()), inbox: inbox)
        let external = root.appendingPathComponent("shared.epub")
        try FileManager.default.copyItem(at: Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub"), to: external)
        await imports.receive(external)?.value
        await imports.receive(external)?.value
        XCTAssertEqual(store.books.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        let invalid = inbox.appendingPathComponent("broken.epub")
        try Data("invalid EPUB".utf8).write(to: invalid)
        for task in imports.recoverInbox() { await task.value }
        XCTAssertNotNil(imports.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertTrue(imports.recoverInbox().isEmpty, "Do not repeat the same failure on every foreground transition")
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(imports.pendingCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.fileURL("Staging").path).isEmpty)
    }

    func testReadingLayoutDefaultsToPaginationForExistingSettings() throws {
        let legacy = Data(#"{"fontSize":150,"theme":"dark"}"#.utf8)
        let settings = try JSONDecoder().decode(ReaderSettings.self, from: legacy)
        XCTAssertEqual(settings.fontSize, 150)
        XCTAssertEqual(settings.theme, "dark")
        XCTAssertEqual(settings.layout, .paginated)
        var scrolling = settings
        scrolling.layout = .scroll
        let restored = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(scrolling))
        XCTAssertEqual(restored.layout, .scroll)
        XCTAssertEqual(restored.fontSize, 150)
        XCTAssertEqual(restored.theme, "dark")
    }

    func testContinuousScrollingCrossesChaptersWithoutPageTurns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        var settings = store.settings; settings.reader.layout = .scroll; try store.saveSettings(settings)
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        let navigator = try XCTUnwrap(session.container.children.first as? ContinuousEPUBController)
        let scroll = navigator.scrollView
        for _ in 0..<100 {
            let views = scroll.subviews.compactMap { $0 as? WKWebView }
            if views.count == 2 && views.allSatisfy({ !$0.isLoading && $0.frame.height > 1000 }) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let chapters = scroll.subviews.compactMap { $0 as? WKWebView }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(chapters.count, 2)
        let first = try XCTUnwrap(chapters.first), second = try XCTUnwrap(chapters.last)
        XCTAssertEqual(first.frame.maxY, second.frame.minY, accuracy: 1, "Chapters must meet in one vertical content flow")
        XCTAssertFalse(first.scrollView.isScrollEnabled)
        XCTAssertFalse(second.scrollView.isScrollEnabled)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        scroll.setContentOffset(CGPoint(x: 0, y: second.frame.minY - 200), animated: false)
        XCTAssertTrue(first.frame.intersects(scroll.bounds))
        XCTAssertTrue(second.frame.intersects(scroll.bounds), "Both chapters must be visible together at the boundary")
        let firstHref = try XCTUnwrap(navigator.currentLocation?.href)
        scroll.setContentOffset(CGPoint(x: 0, y: second.frame.minY + 250), animated: false)
        XCTAssertNotEqual(navigator.currentLocation?.href, firstHref, "One uninterrupted scroll crosses the chapter boundary")
        await session.flush()
        let saved = try XCTUnwrap(store.book(book.id)?.position)
        XCTAssertEqual(try EPUBPositionBridge.spineIndex(XCTUnwrap(saved.xpointer)), 1)
        let visible = try await readingAnchorIsVisible(XCTUnwrap(saved.xpointer), in: navigator)
        XCTAssertTrue(visible, "Progress must capture the visible text rather than the chapter's first paragraph")
        scroll.setContentOffset(CGPoint(x: 0, y: second.frame.minY - 1000), animated: false)
        XCTAssertEqual(navigator.currentLocation?.href, firstHref, "Reverse scrolling also crosses without a separate navigation action")
        XCTAssertNil(session.error)
        await session.close()
    }

    func testContinuousReflowAndForegroundPreserveTextAnchor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        var settings = store.settings; settings.reader.layout = .scroll; try store.saveSettings(settings)
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        await session.go(try XCTUnwrap(session.contents.last))
        let initial = try XCTUnwrap(session.container.children.first as? ContinuousEPUBController)
        try await Task.sleep(nanoseconds: 300_000_000)
        initial.scrollView.setContentOffset(CGPoint(x: 0, y: initial.scrollView.contentOffset.y + 800), animated: false)
        await session.flush()
        var checkpoint = try XCTUnwrap(store.book(book.id))
        let saved = try XCTUnwrap(checkpoint.position)
        XCTAssertEqual(try EPUBPositionBridge.spineIndex(XCTUnwrap(saved.xpointer)), 1)
        checkpoint.pendingSync = false; try store.save(checkpoint)
        for change in 0..<3 {
            if change == 0 {
                settings.reader.fontSize = 150; try store.saveSettings(settings); session.updatePreferences()
            } else if change == 1 {
                session.container.view.frame.size = CGSize(width: 700, height: 500)
                session.container.view.setNeedsLayout(); session.container.view.layoutIfNeeded()
            } else {
                await session.background(); await session.foreground()
            }
            for _ in 0..<100 {
                if !session.isRestoring { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertFalse(session.isRestoring)
            XCTAssertNil(session.recoveryError)
            let navigator = try XCTUnwrap(session.container.children.first as? ContinuousEPUBController)
            let visible = try await readingAnchorIsVisible(XCTUnwrap(saved.xpointer), in: navigator)
            XCTAssertTrue(visible, "Change \(change) must preserve the same visible character")
            await session.flush()
            XCTAssertEqual(store.book(book.id)?.position, saved)
            XCTAssertFalse(try XCTUnwrap(store.book(book.id)).pendingSync)
        }
        await session.close()
    }

    func testContinuousImagesAndShortFinalChapterKeepOriginalPointers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        var settings = store.settings; settings.reader.layout = .scroll; try store.saveSettings(settings)
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("image-only.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
            sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = session.container; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let navigator = try XCTUnwrap(session.container.children.first as? ContinuousEPUBController)
        XCTAssertNil(session.error)
        XCTAssertEqual(store.book(book.id)?.position?.xpointer, "/body/DocFragment[1]/body/img")
        let loaded = try await navigator.evaluateJavaScript("Array.from(document.images).every(image => image.complete && image.naturalWidth > 0)").get() as! Bool
        XCTAssertTrue(loaded, "Chapter-relative image resources must remain available")
        let pointer = "/body/DocFragment[2]/body"
        let target = try await EPUBPositionBridge.locator(pointer: pointer, navigator: navigator)
        let moved = await navigator.go(to: target)
        XCTAssertTrue(moved, "The final short chapter must resolve in its own document even when the viewport also shows the previous one")
        let captured = try await EPUBPositionBridge.capture(navigator: navigator, locator: target)
        XCTAssertEqual(captured, pointer)
        XCTAssertNil(session.error)
        await session.close()
    }

    func testImmersiveControlsDoNotResizeHostedReaderOrChangeProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for layout in [ReadingLayout.paginated, .scroll] {
            let store = try LibraryStore(root: root.appendingPathComponent(layout.rawValue), inMemory: true)
            let readium = ReadiumService(), sync = SyncCoordinator(store: store, http: HTTPClient())
            var settings = store.settings; settings.reader.layout = layout; try store.saveSettings(settings)
            let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
            let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: sync)
            session.toggleControls()
            XCTAssertTrue(session.controlsVisible, "Loading controls must remain accessible")
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: ReaderView(session: session, store: store, sync: sync))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<300 {
                if session.ready && !session.isRestoring { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(session.ready)
            await session.go(try XCTUnwrap(session.contents.last))
            try await Task.sleep(nanoseconds: 600_000_000)
            await session.flush()
            let navigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
            let position = try XCTUnwrap(store.book(book.id)?.position)
            let viewport = session.container.view.bounds
            let location = navigator.currentLocation
            let pointer = try XCTUnwrap(position.xpointer)
            let anchorScript = """
            (() => {
              const anchor=SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(pointer)));
              const element=document.querySelector(anchor.cssSelector);
              const node=element.childNodes[anchor.textNodeIndex] || element;
              const range=document.createRange();
              if(node.nodeType===Node.TEXT_NODE) {range.setStart(node,anchor.textOffset);range.setEnd(node,Math.min(node.length,anchor.textOffset+1));}
              else range.selectNode(node);
              const rect=range.getBoundingClientRect();return JSON.stringify([rect.x,rect.y]);
            })();
            """
            _ = try await navigator.evaluateJavaScript(try EPUBPositionBridge.source).get()
            let beforeResult = try await navigator.evaluateJavaScript(anchorScript).get()
            let glyphBefore = try XCTUnwrap(beforeResult as? String)
            if let epub = navigator as? EPUBNavigatorViewController {
                session.navigator(epub, didTapAt: CGPoint(x: 5, y: 100))
                XCTAssertTrue(session.controlsVisible, "Edge gestures must not toggle controls")
                session.navigator(epub, didTapAt: CGPoint(x: viewport.midX, y: viewport.midY))
            } else {
                _ = try await navigator.evaluateJavaScript("const button=document.createElement('button');button.dataset.simpleReaderInert='';document.body.append(button);button.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:innerWidth/2,clientY:20}));button.remove();true").get()
                try await Task.sleep(nanoseconds: 350_000_000)
                XCTAssertTrue(session.controlsVisible, "Interactive content must keep its own tap behavior")
                _ = try await navigator.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:innerWidth/2,clientY:20}));true").get()
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertFalse(session.controlsVisible)
            host.view.layoutIfNeeded()
            XCTAssertEqual(session.container.view.bounds, viewport, "Hiding overlays must not reflow the reading surface")
            XCTAssertEqual(navigator.currentLocation, location)
            let glyphAfter = try await navigator.evaluateJavaScript(anchorScript).get() as? String
            XCTAssertEqual(glyphAfter, glyphBefore, "The same glyph must stay at the same screen position")
            await session.flush()
            XCTAssertEqual(store.book(book.id)?.position, position)
            session.toggleControls()
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertTrue(session.controlsVisible)
            XCTAssertEqual(session.container.view.bounds, viewport)
            session.resignActive()
            let visibility = session.controlsVisible
            session.toggleControls()
            XCTAssertEqual(session.controlsVisible, visibility, "Recovery must not change control visibility")
            await session.close()
        }
    }

    func testReadingLayoutSwitchPreservesAnchorWithoutCreatingUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true), readium = ReadiumService()
        let book = try await BookImportService(store: store, readium: readium).importBook(from: fixture("sample.epub"))
        let session = ReaderSession(bookID: book.id, store: store, readium: readium,
                                    sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        host.addChild(session.container); host.view.addSubview(session.container.view)
        session.container.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 650)
        session.container.didMove(toParent: host)
        defer { window.isHidden = true }
        await session.load()
        for _ in 0..<2 {
            await session.turn(forward: true)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.flush()
        var checkpoint = try XCTUnwrap(store.book(book.id))
        let saved = try XCTUnwrap(checkpoint.position)
        XCTAssertGreaterThan(saved.progression, 0)
        checkpoint.pendingSync = false; try store.save(checkpoint)
        XCTAssertTrue(session.supportsScrolling)
        for layout in [ReadingLayout.scroll, .paginated, .scroll] {
            var settings = store.settings; settings.reader.layout = layout; try store.saveSettings(settings)
            session.updatePreferences()
            XCTAssertTrue(session.isRestoring)
            for _ in 0..<50 {
                if !session.isRestoring { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertFalse(session.isRestoring)
            XCTAssertNil(session.recoveryError)
            let navigator = try XCTUnwrap(session.container.children.first as? EPUBReadingNavigator)
            XCTAssertEqual(navigator is ContinuousEPUBController, layout == .scroll)
            if layout == .scroll {
                XCTAssertFalse(session.container.canTurnPage?() ?? true)
            } else {
                XCTAssertFalse(try XCTUnwrap(navigator as? EPUBNavigatorViewController).settings.scroll)
            }
            let visible = try await readingAnchorIsVisible(XCTUnwrap(saved.xpointer), in: navigator)
            XCTAssertTrue(visible, "Switching layouts must keep the original text in view")
            await session.flush()
            XCTAssertEqual(store.book(book.id)?.position, saved)
            XCTAssertFalse(try XCTUnwrap(store.book(book.id)).pendingSync)
        }
        await session.close()
    }
}
