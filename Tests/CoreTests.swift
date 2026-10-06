import XCTest
@testable import SimpleReader

final class CoreTests: XCTestCase {
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
