import XCTest
import UIKit
import ReadiumNavigator
@testable import SimpleReader

final class CoreTests: XCTestCase {
    @MainActor func testReaderThemeDefaultsToSystemAndMigratesWarmTheme() throws {
        XCTAssertEqual(ReaderSettings().theme, "system")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var settings = store.settings
        settings.reader.theme = "sepia"
        try store.saveSettings(settings)
        let restored = try LibraryStore(root: root)
        XCTAssertEqual(restored.settings.reader.theme, "system")
    }

    @MainActor func testEPUBThemeFollowsAppearanceAndPreservesManualChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        var settings = store.settings
        settings.reader.theme = "system"
        try store.saveSettings(settings)
        let readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = session.container
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await session.load()
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        XCTAssertEqual(navigator.settings.theme, .dark)
        window.overrideUserInterfaceStyle = .light
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(navigator.settings.theme, .light)
        window.overrideUserInterfaceStyle = .dark
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(navigator.settings.theme, .dark)
        settings.reader.theme = "light"
        try store.saveSettings(settings)
        session.updatePreferences()
        XCTAssertEqual(navigator.settings.theme, .light)
        window.overrideUserInterfaceStyle = .light
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(navigator.settings.theme, .light)
        settings.reader.theme = "dark"
        try store.saveSettings(settings)
        session.updatePreferences()
        XCTAssertEqual(navigator.settings.theme, .dark)
        settings.reader.theme = "system"
        try store.saveSettings(settings)
        session.updatePreferences()
        XCTAssertEqual(navigator.settings.theme, .light)
        await session.close()
    }

    func testReaderPageLayoutUsesAvailableIPadViewport() {
        XCTAssertTrue(ReaderPageLayout.displaysTwoPages(size: CGSize(width: 1024, height: 660), idiom: .pad))
        XCTAssertTrue(ReaderPageLayout.displaysTwoPages(size: CGSize(width: 1194, height: 720), idiom: .pad))
        XCTAssertFalse(ReaderPageLayout.displaysTwoPages(size: CGSize(width: 768, height: 924), idiom: .pad))
        XCTAssertFalse(ReaderPageLayout.displaysTwoPages(size: CGSize(width: 507, height: 660), idiom: .pad))
        XCTAssertFalse(ReaderPageLayout.displaysTwoPages(size: CGSize(width: 650, height: 500), idiom: .pad))
        XCTAssertFalse(ReaderPageLayout.displaysTwoPages(size: CGSize(width: 844, height: 300), idiom: .phone))
        XCTAssertFalse(ReaderPageLayout.displaysTwoPages(size: .zero, idiom: .pad))
    }

    func testPDFTurnsAdvanceWholeSpreadsFromEitherVisiblePage() {
        XCTAssertEqual(ReaderPageLayout.nextPDFPage(current: 0, forward: true, twoPages: true), 2)
        XCTAssertEqual(ReaderPageLayout.nextPDFPage(current: 1, forward: true, twoPages: true), 2)
        XCTAssertEqual(ReaderPageLayout.nextPDFPage(current: 3, forward: false, twoPages: true), 0)
        XCTAssertEqual(ReaderPageLayout.nextPDFPage(current: 4, forward: false, twoPages: true), 2)
        XCTAssertEqual(ReaderPageLayout.nextPDFPage(current: 1, forward: true, twoPages: false), 2)
        XCTAssertEqual(ReaderPageLayout.nextPDFPage(current: 1, forward: false, twoPages: false), 0)
    }

    @MainActor func testEPUBPageLayoutFollowsContainerResizeAndFontChanges() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Requires an iPad simulator") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        let readium = ReadiumService()
        let file = Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/sample.epub")
        let book = try await BookImportService(store: store, readium: readium).importBook(from: file)
        let session = ReaderSession(bookID: book.id, store: store, readium: readium, sync: SyncCoordinator(store: store, http: HTTPClient()))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        host.addChild(session.container)
        host.view.addSubview(session.container.view)
        session.container.didMove(toParent: host)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func resize(_ size: CGSize) {
            session.container.view.frame = CGRect(origin: .zero, size: size)
            session.container.view.setNeedsLayout()
            session.container.view.layoutIfNeeded()
        }
        resize(CGSize(width: 1024, height: 660))
        await session.load()
        XCTAssertTrue(session.ready, session.error ?? "Reader did not become ready")
        let navigator = try XCTUnwrap(session.container.children.first as? EPUBNavigatorViewController)
        XCTAssertEqual(navigator.settings.columnCount, .two)
        XCTAssertEqual(navigator.settings.spread, .always)
        let columns = try await navigator.evaluateJavaScript("getComputedStyle(document.documentElement).columnCount").get() as? String
        XCTAssertEqual(columns, "2", "The actual EPUB WebKit viewport must render two columns")
        var settings = store.settings
        settings.reader.fontSize = 200
        try store.saveSettings(settings)
        session.updatePreferences()
        XCTAssertEqual(navigator.settings.columnCount, .two, "Increasing text size must retain landscape's two pages")
        try await Task.sleep(nanoseconds: 500_000_000)
        let enlargedColumns = try await navigator.evaluateJavaScript("getComputedStyle(document.documentElement).columnCount").get() as? String
        XCTAssertEqual(enlargedColumns, "2", "The rendered spread must retain two columns at 200% text size")
        resize(CGSize(width: 768, height: 924))
        XCTAssertEqual(navigator.settings.columnCount, .one)
        XCTAssertEqual(navigator.settings.spread, .never)
        resize(CGSize(width: 1024, height: 660))
        XCTAssertEqual(navigator.settings.columnCount, .two)
        resize(CGSize(width: 507, height: 660))
        XCTAssertEqual(navigator.settings.columnCount, .one, "A narrow iPad window must return to one page")
        await session.close()
    }

    func testKOReaderHashUsesSampledWindowsAndOriginalFilename() throws {
        let data = Data((0..<20000).map { UInt8(($0*7)%251) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let identity = try BookHashing.identity(file: url, filename: "中文.epub")
        var sampled = Data()
        for offset in [0,1024,4096,16384] { sampled.append(data.subdata(in: offset..<min(offset+1024,data.count))) }
        XCTAssertEqual(identity.partialMD5, BookHashing.md5(sampled))
        XCTAssertEqual(identity.filenameMD5, BookHashing.md5(Data("中文.epub".utf8)))
        let renamed = try BookHashing.identity(file: url, filename: "other.epub")
        XCTAssertEqual(identity.sha256, renamed.sha256); XCTAssertEqual(identity.partialMD5, renamed.partialMD5); XCTAssertNotEqual(identity.filenameMD5, renamed.filenameMD5)
    }
    func testOPDSNamespacesBasePaginationAndAcquisition() throws {
        let xml = try Data(contentsOf: fixture("catalog.xml"))
        let catalog = try OPDSParser.parse(xml, base: URL(string: "https://example.com/opds")!)
        XCTAssertEqual(catalog.title, "Calibre")
        XCTAssertEqual(catalog.next?.absoluteString, "https://example.com/opds/?page=2")
        XCTAssertEqual(catalog.entries[0].author, "作者一, 作者二")
        XCTAssertEqual(catalog.entries[0].downloads[0].url.absoluteString, "https://example.com/books/sample.epub")
        XCTAssertNotNil(catalog.entries[1].navigation); XCTAssertNotNil(catalog.search)
        XCTAssertThrowsError(try OPDSParser.parse(Data("<html>login</html>".utf8), base: URL(string: "https://example.com")!))
    }
    func testNetworkPolicyAndCrossOriginCredentialStripping() throws {
        for url in ["https://example.com", "http://192.168.1.8:8080", "http://calibre.local", "http://[::1]"] { XCTAssertNoThrow(try NetworkPolicy.validate(URL(string: url)!)) }
        for url in ["http://example.com", "ftp://192.168.1.8", "https://user:pass@example.com"] { XCTAssertThrowsError(try NetworkPolicy.validate(URL(string: url)!)) }
        let origin = URL(string: "https://example.com")!
        let client = HTTPClient()
        let request = try client.request(origin, credentials: ServerCredentials(origin: origin, username: "user", password: "pass"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        let other = URL(string: "https://cdn.example.com/book")!
        XCTAssertNil(try client.request(other, credentials: ServerCredentials(origin: origin, username: "user", password: "pass")).value(forHTTPHeaderField: "Authorization"))
        var redirected = URLRequest(url: other)
        redirected.setValue("secret", forHTTPHeaderField: "Authorization"); redirected.setValue("secret", forHTTPHeaderField: "X-Auth-Key")
        let delegate = CredentialGuard(origin: origin)
        let task = URLSession.shared.dataTask(with: origin)
        delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: redirected) { result in
            XCTAssertNil(result?.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(result?.value(forHTTPHeaderField: "X-Auth-Key"))
        }
        task.cancel()
    }
    func testHTTPPolicyAcceptsLocalRangesAndRejectsAdjacentPublicAddresses() throws {
        let localHosts = [
            "localhost", "calibre.local", "calibre", "10.0.0.1", "127.0.0.1",
            "192.168.0.1", "172.16.0.1", "172.31.255.254", "169.254.0.1",
            "[::1]", "[fc00::1]", "[fd00::1]", "[fe80::1]"
        ]
        let publicHosts = [
            "example.com", "11.0.0.1", "126.0.0.1", "192.167.0.1",
            "172.15.255.254", "172.32.0.1", "169.253.0.1", "[2001:db8::1]"
        ]
        for host in localHosts {
            let url = try XCTUnwrap(URL(string: "http://\(host)"))
            XCTAssertNoThrow(try NetworkPolicy.validate(url), host)
        }
        for host in publicHosts {
            let url = try XCTUnwrap(URL(string: "http://\(host)"))
            XCTAssertThrowsError(try NetworkPolicy.validate(url), host)
        }
    }

    func testKeychainRoundTripInSignedSimulator() throws {
        let key = "test-" + UUID().uuidString
        defer { KeychainService.delete(key) }
        XCTAssertEqual(try KeychainService.read(key), "")
        try KeychainService.save("secret", key: key)
        XCTAssertEqual(try KeychainService.read(key), "secret")
        try KeychainService.save("updated", key: key)
        XCTAssertEqual(try KeychainService.read(key), "updated")
    }
    func testOriginalSpineKeepsNonlinearItems() throws {
        let xml = Data("<package><manifest><item id='a' href='a.xhtml'/><item id='n' href='notes.xhtml'/><item id='b' href='b.xhtml'/></manifest><spine><itemref idref='a'/><itemref idref='n' linear='no'/><itemref idref='b'/></spine></package>".utf8)
        let spine = try EPUBSpineParser.parse(xml).hrefs(relativeTo: "EPUB/package.opf")
        XCTAssertEqual(spine, ["EPUB/a.xhtml", "EPUB/notes.xhtml", "EPUB/b.xhtml"])
    }
    func testConflictDecisionDoesNotTreatFurtherAsNewer() {
        var book = sampleBook()
        let remote = RemoteProgress(progress: "/body/DocFragment/body/p", percentage: 0.2, timestamp: 100, device_id: "other")
        book.pendingSync = true
        XCTAssertEqual(SyncDecision.decide(book: book, remote: remote), .conflict(remote))
        book.remoteBaseline = remote.fingerprint
        XCTAssertEqual(SyncDecision.decide(book: book, remote: remote), .push)
        book.pendingSync = false
        XCTAssertEqual(SyncDecision.decide(book: book, remote: remote), .unchanged)
        book.remoteBaseline = nil
        XCTAssertEqual(SyncDecision.decide(book: book, remote: remote), .pull(remote))
        XCTAssertEqual(SyncDecision.decide(book: book, remote: nil), .unchanged)
    }
    @MainActor func testPersistenceRetainsPendingProgressAndStableDeviceID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LibraryStore(root: root)
        var book = sampleBook(); book.pendingSync = true
        try first.save(book)
        let device = first.settings.sync.deviceID
        let second = try LibraryStore(root: root)
        XCTAssertEqual(second.books.first, book)
        XCTAssertEqual(second.settings.sync.deviceID, device)
    }
    @MainActor func testBatchDeletionRemovesOnlySelectedBooksAndPersistsAcrossReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root)
        var fixtures: [Book] = []
        for index in 0..<3 {
            var book = sampleBook()
            book.filePath = "Books/\(index).epub"
            book.coverPath = "Covers/\(index).jpg"
            book.pendingSync = true
            try Data("book".utf8).write(to: store.fileURL(book.filePath))
            try Data("cover".utf8).write(to: store.fileURL(book.coverPath!))
            try store.save(book)
            fixtures.append(book)
        }
        let deviceID = store.settings.sync.deviceID
        try store.delete([fixtures[0], fixtures[2], fixtures[0]])
        XCTAssertEqual(store.books, [fixtures[1]])
        for book in [fixtures[0], fixtures[2]] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(book.filePath).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(book.coverPath!).path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(fixtures[1].filePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(fixtures[1].coverPath!).path))
        try store.delete([])
        try store.delete([fixtures[0]])
        let reloaded = try LibraryStore(root: root)
        XCTAssertEqual(reloaded.books, [fixtures[1]])
        XCTAssertEqual(reloaded.settings.sync.deviceID, deviceID)
        try reloaded.delete(fixtures[1])
        XCTAssertTrue(reloaded.books.isEmpty)
        XCTAssertTrue(try LibraryStore(root: root).books.isEmpty)
    }
    @MainActor func testOfflineUploadChecksRemoteAndRetainsChangesMadeDuringUpload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(root: root, inMemory: true)
        var settings = store.settings; settings.sync.enabled = true; try store.saveSettings(settings)
        var book = sampleBook(); book.pendingSync = true; try store.save(book)
        let fake = FakeSync()
        let sync = SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { fake })
        fake.remote = RemoteProgress(progress: "remote", percentage: 0.7, timestamp: 10, device_id: "other")
        _ = try await sync.synchronize(book.id)
        XCTAssertEqual(fake.putCount, 0)
        book.remoteBaseline = fake.remote?.fingerprint; try store.save(book)
        fake.onPut = {
            var changed = store.book(book.id)!
            changed.position?.progression = 0.9; changed.position?.xpointer = "/body/DocFragment/body/p[9]"; changed.position?.updatedAt = Date()
            try! store.save(changed)
        }
        _ = try await sync.synchronize(book.id)
        XCTAssertEqual(fake.putCount, 1)
        XCTAssertTrue(store.book(book.id)!.pendingSync)
        XCTAssertEqual(store.book(book.id)!.position?.progression, 0.9)
    }
    func fixture(_ name: String) -> URL { Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures/\(name)") }
    func sampleBook() -> Book {
        Book(id: UUID(), title: "测试", author: "", originalFilename: "sample.epub", filePath: "Books/sample.epub", format: .epub, identity: .init(sha256: "hash", partialMD5: "document", filenameMD5: "filename"), addedAt: Date(), position: ReadingPosition(progression: 0.5, xpointer: "/body/DocFragment/body/p[5]", updatedAt: Date()))
    }
}
@MainActor private final class FakeSync: ProgressSyncClient {
    var remote: RemoteProgress?
    var putCount = 0
    var onPut: (() -> Void)?
    func get(document: String) async throws -> RemoteProgress? { remote }
    func put(document: String, position: ReadingPosition, deviceID: String) async throws {
        putCount += 1; onPut?()
        remote = RemoteProgress(document: document, progress: position.xpointer, percentage: position.progression, timestamp: 101, device_id: deviceID)
    }
}
