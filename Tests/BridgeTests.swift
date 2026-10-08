import XCTest
import WebKit
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
        remote = RemoteProgress(document: document, progress: position.xpointer, percentage: position.progression, timestamp: Double(uploaded.count), device_id: deviceID)
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
}
