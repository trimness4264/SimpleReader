import XCTest
@testable import SimpleReader

@MainActor final class SyncCoordinatorTests: XCTestCase {
    func testConflictingRemotePositionPreservesLocalProgress() async throws {
        let store = try library()
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        var book = sampleBook()
        book.pendingSync = true
        try store.save(book)
        let server = ProgressServer()
        let remote = RemoteProgress(progress: "8", percentage: 0.8, timestamp: 200, device_id: "other")
        server.remote = remote
        let sync = SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server })

        let outcome = try await sync.synchronize(book.id)

        guard case .conflict(let conflict) = outcome else { return XCTFail("Expected a choice between local and remote progress") }
        XCTAssertEqual(conflict, remote)
        XCTAssertEqual(store.book(book.id), book)
        XCTAssertEqual(server.remote, remote)
    }

    func testReadingDuringUploadKeepsNewerPositionPending() async throws {
        let (store, book, server, sync) = try pendingSync()
        let newer = readingPosition(6)
        server.onUpload = {
            var changed = try XCTUnwrap(store.book(book.id))
            changed.position = newer
            try store.save(changed)
        }

        _ = try await sync.synchronize(book.id)

        let saved = try XCTUnwrap(store.book(book.id))
        XCTAssertEqual(saved.position, newer)
        XCTAssertTrue(saved.pendingSync)
        XCTAssertEqual(server.remote?.progress, "3")
        XCTAssertEqual(saved.remoteBaseline, server.remote?.fingerprint)
    }

    func testUnconfirmedUploadRemainsPending() async throws {
        let (store, book, server, sync) = try pendingSync()
        server.confirmsUpload = false

        _ = try await sync.synchronize(book.id)

        XCTAssertEqual(store.book(book.id), book)
    }

    func testConfirmedUploadClearsPendingFlag() async throws {
        let (store, book, server, sync) = try pendingSync()

        _ = try await sync.synchronize(book.id)

        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
        XCTAssertEqual(store.book(book.id)?.remoteBaseline, server.remote?.fingerprint)
    }

    func testAccountChangeWhileReadingRemoteProgressRejectsOldResponse() async throws {
        let (store, book, server, sync) = try pendingSync()
        server.onRead = {
            var settings = store.settings
            settings.sync.username = "another-account"
            try store.saveSettings(settings)
        }

        do {
            _ = try await sync.synchronize(book.id)
            XCTFail("A response for the old account must not be uploaded")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "Sync settings changed. Try again."))
        }

        XCTAssertNil(server.remote)
        XCTAssertEqual(store.book(book.id), book)
    }

    private func pendingSync() throws -> (LibraryStore, Book, ProgressServer, SyncCoordinator) {
        let store = try library()
        var settings = store.settings
        settings.sync.enabled = true
        try store.saveSettings(settings)
        var book = sampleBook()
        book.pendingSync = true
        try store.save(book)
        let server = ProgressServer()
        return (store, book, server, SyncCoordinator(store: store, http: HTTPClient(), clientFactory: { server }))
    }
}

// Adapter for the remote sync server; the coordinator and library remain real.
@MainActor final class ProgressServer: ProgressSyncClient {
    var remote: RemoteProgress?
    var onUpload: (() async throws -> Void)?
    var onRead: (() throws -> Void)?
    var confirmsUpload = true

    func get(document: String) async throws -> RemoteProgress? {
        try onRead?()
        return remote
    }

    func put(document: String, position: ReadingPosition, deviceID: String) async throws {
        try await onUpload?()
        if confirmsUpload {
            remote = RemoteProgress(document: document, progress: position.pdfPage.map { String($0 + 1) } ?? position.xpointer,
                percentage: position.progression, timestamp: 200, device_id: deviceID)
        }
    }
}
