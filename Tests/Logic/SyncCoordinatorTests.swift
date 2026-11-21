import XCTest
import Combine
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
        XCTAssertEqual(conflict.remote, remote)
        XCTAssertEqual(store.book(book.id), book)
        XCTAssertEqual(server.remote, remote)
    }

    func testReadingDuringUploadSchedulesTheNewPosition() async throws {
        let (store, book, server, sync) = try pendingSync()
        let newer = readingPosition(6)
        var uploads = 0
        server.onUpload = {
            uploads += 1
            var latest = try XCTUnwrap(store.book(book.id))
            if uploads == 1 {
                latest.position = newer
                try store.save(latest)
            } else {
                XCTAssertEqual(latest.position, newer)
                XCTAssertTrue(latest.pendingSync)
                XCTAssertNotNil(latest.remoteBaseline)
            }
        }

        _ = try await sync.synchronize(book.id)

        let saved = try XCTUnwrap(store.book(book.id))
        XCTAssertEqual(saved.position, newer)
        XCTAssertFalse(saved.pendingSync)
        XCTAssertEqual(server.uploads.map(\.progress), ["3", "7"])
        XCTAssertEqual(server.remote?.progress, "7")
        XCTAssertEqual(saved.remoteBaseline, server.remote?.fingerprint)
    }

    func testUnconfirmedUploadRemainsPending() async throws {
        let (store, book, server, sync) = try pendingSync()
        server.confirmsUpload = false

        _ = try await sync.synchronize(book.id)

        XCTAssertEqual(store.book(book.id), book)
    }

    func testAnOverwrittenUploadDoesNotConfirmEvenWhenThePointerMatches() async throws {
        let rewrites: [(inout RemoteProgress) -> Void] = [
            { $0.device = "Another reader" }, { $0.device_id = "another-device" },
            { $0.percentage = 0.8 }, { $0.timestamp = 201 }
        ]
        for rewrite in rewrites {
            let (store, book, server, sync) = try pendingSync()
            server.rewriteUpload = rewrite

            let outcome = try await sync.synchronize(book.id)

            guard case .unconfirmed = outcome else { return XCTFail("Expected the rewritten upload to stay pending") }
            XCTAssertEqual(server.remote?.progress, "3")
            XCTAssertEqual(store.book(book.id), book)
        }
    }

    func testStartupRetriesProgressFromTheLibraryAfterATransportFailure() async throws {
        let (store, book, _, _) = try pendingSync(inMemory: false)
        let reloaded = try LibraryStore(root: store.root)
        let server = ProgressServer()
        server.onRead = { [weak server] in
            if server?.reads == 1 { throw URLError(.networkConnectionLost) }
        }
        let sync = SyncCoordinator(store: reloaded, http: HTTPClient(), clientFactory: { server })
        let finished = expectation(description: "The persisted upload is retried and confirmed")
        let updates = reloaded.$books.first { $0.first(where: { $0.id == book.id })?.pendingSync == false }
            .sink { _ in finished.fulfill() }

        sync.start()
        await fulfillment(of: [finished], timeout: 12)

        XCTAssertEqual(reloaded.book(book.id)?.pendingSync, false)
        XCTAssertEqual(server.uploads.map(\.progress), ["3"])
        XCTAssertGreaterThanOrEqual(server.reads, 3)
        withExtendedLifetime((sync, updates)) {}
    }

    func testRestartConfirmsAnUploadWhoseReadbackFailed() async throws {
        let (store, book, server, sync) = try pendingSync(inMemory: false)
        let newer = readingPosition(6)
        server.onUpload = {
            var latest = try XCTUnwrap(store.book(book.id))
            latest.position = newer
            try store.save(latest)
        }
        server.onRead = { [weak server] in
            if server?.reads == 2 { throw URLError(.networkConnectionLost) }
        }
        do {
            _ = try await sync.synchronize(book.id)
            XCTFail("Expected the first readback to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(store.book(book.id)?.pendingSync, true)

        let reloaded = try LibraryStore(root: store.root)
        server.onUpload = nil
        let restarted = SyncCoordinator(store: reloaded, http: HTTPClient(), clientFactory: { server })
        _ = try await restarted.synchronize(book.id)

        XCTAssertEqual(reloaded.book(book.id)?.position, newer)
        XCTAssertEqual(reloaded.book(book.id)?.pendingSync, false)
        XCTAssertEqual(server.uploads.map(\.progress), ["3", "7"])
    }

    func testUnchangedRemoteSnapshotDoesNotConfirmAnUnacknowledgedWrite() async throws {
        let (store, book, server, sync) = try pendingSync()
        let before = RemoteProgress(document: book.identity.partialMD5, progress: "3", percentage: 0.25, timestamp: 199,
            device: "Simple Reader", device_id: store.settings.sync.deviceID)
        server.remote = before
        var pending = book
        pending.remoteBaseline = before.legacyFingerprint
        try store.save(pending)
        server.onUpload = { throw URLError(.networkConnectionLost) }
        do {
            _ = try await sync.synchronize(book.id)
            XCTFail("Expected PUT to fail before the server received it")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(store.book(book.id)?.pendingSync, true)

        server.onUpload = nil
        _ = try await sync.synchronize(book.id)

        XCTAssertEqual(server.uploads.count, 2)
        XCTAssertNotEqual(server.remote, before)
        XCTAssertEqual(store.book(book.id)?.pendingSync, false)
    }

    func testConcurrentChecksForOneBookShareTheRemoteOffer() async throws {
        let (_, book, server, sync) = try pendingSync()
        server.remote = RemoteProgress(progress: "8", percentage: 0.8, timestamp: 200, device_id: "other")
        let readStarted = expectation(description: "First check reached the server")
        let secondStarted = expectation(description: "Second check requested the same book")
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        server.onRead = { [weak server] in
            if server?.reads == 1 {
                readStarted.fulfill()
                for await _ in gate { break }
            }
        }
        let first = Task { try await sync.synchronize(book.id) }
        await fulfillment(of: [readStarted], timeout: 5)
        let second = Task {
            secondStarted.fulfill()
            return try await sync.synchronize(book.id)
        }
        await fulfillment(of: [secondStarted], timeout: 5)
        release.finish()

        guard case .conflict(let firstOffer) = try await first.value,
              case .conflict(let secondOffer) = try await second.value else { return XCTFail("Both callers must see the conflict") }
        XCTAssertEqual(firstOffer, secondOffer)
        XCTAssertEqual(server.reads, 1)
    }

    func testConcurrentChecksForTheSameDocumentShareTheServerRead() async throws {
        let (store, book, server, sync) = try pendingSync()
        var settings = store.settings
        settings.sync.filenameMatching = true
        try store.saveSettings(settings)
        var otherEdition = sampleBook()
        otherEdition.identity.partialMD5 = "other-edition"
        try store.save(otherEdition)
        server.remote = RemoteProgress(progress: "8", percentage: 0.8, timestamp: 200, device_id: "other")
        let readStarted = expectation(description: "First book reached the server")
        let secondStarted = expectation(description: "Other book requested the same document")
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        server.onRead = { [weak server] in
            if server?.reads == 1 {
                readStarted.fulfill()
                for await _ in gate { break }
            }
        }
        let first = Task { try await sync.synchronize(book.id) }
        await fulfillment(of: [readStarted], timeout: 5)
        let second = Task {
            secondStarted.fulfill()
            return try await sync.synchronize(otherEdition.id)
        }
        await fulfillment(of: [secondStarted], timeout: 5)
        release.finish()

        guard case .conflict(let conflict) = try await first.value,
              case .remote(let download) = try await second.value else { return XCTFail("Each book must get its own decision") }
        XCTAssertEqual(conflict.remote, download.remote)
        XCTAssertEqual(server.reads, 1)

        server.remote = RemoteProgress(progress: "9", percentage: 0.9, timestamp: 201, device_id: "other")
        server.onRead = { try store.delete(otherEdition) }
        _ = try await sync.synchronize(otherEdition.id)
        XCTAssertNil(store.book(otherEdition.id))
        XCTAssertFalse(sync.isCurrent(conflict))
        XCTAssertThrowsError(try sync.acceptRemote(conflict, position: readingPosition(7)))
    }

    func testConflictConfirmationWithNewerLocalProgressKeepsTheNewPositionPending() async throws {
        let (store, book, server, sync) = try pendingSync()
        server.remote = RemoteProgress(progress: "8", percentage: 0.8, timestamp: 200, device_id: "other")
        guard case .conflict(let offer) = try await sync.synchronize(book.id) else { return XCTFail("Expected a conflict") }
        let newer = readingPosition(6)
        server.onRead = {
            var latest = try XCTUnwrap(store.book(book.id))
            latest.position = newer
            try store.save(latest)
        }

        let resolution = SyncCoordinator.ConflictResolution(offer: offer, isStillValid: { true })
        guard case .conflict(let refreshed) = try await sync.synchronize(book.id, resolving: resolution) else {
            return XCTFail("Expected a fresh conflict after the local position changed")
        }
        XCTAssertNotEqual(refreshed, offer)
        XCTAssertFalse(sync.isCurrent(offer))
        XCTAssertThrowsError(try sync.acceptRemote(offer, position: readingPosition(7)))
        XCTAssertTrue(server.uploads.isEmpty)
        XCTAssertEqual(store.book(book.id)?.position, newer)
        XCTAssertEqual(store.book(book.id)?.pendingSync, true)
    }

    func testReaderMovementDuringConflictRecheckPreventsUploadingBeforeThePositionIsSaved() async throws {
        let (store, book, server, sync) = try pendingSync()
        server.remote = RemoteProgress(progress: "8", percentage: 0.8, timestamp: 200, device_id: "other")
        guard case .conflict(let offer) = try await sync.synchronize(book.id) else { return XCTFail("Expected a conflict") }
        var readerMoved = false
        server.onRead = { readerMoved = true }
        let resolution = SyncCoordinator.ConflictResolution(offer: offer, isStillValid: { !readerMoved })

        _ = try await sync.synchronize(book.id, resolving: resolution)

        XCTAssertTrue(readerMoved)
        XCTAssertTrue(server.uploads.isEmpty)
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

    private func pendingSync(inMemory: Bool = true) throws -> (LibraryStore, Book, ProgressServer, SyncCoordinator) {
        let store = try library(inMemory: inMemory)
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
    var onRead: (() async throws -> Void)?
    var confirmsUpload = true
    var rewriteUpload: ((inout RemoteProgress) -> Void)?
    private(set) var reads = 0
    private(set) var uploads: [RemoteProgress] = []

    func get(document: String) async throws -> RemoteProgress? {
        reads += 1
        try await onRead?()
        return remote
    }

    func put(_ progress: RemoteProgress) async throws -> RemoteProgress {
        uploads.append(progress)
        try await onUpload?()
        let timestamp = 200.0
        if confirmsUpload {
            var saved = progress
            saved.timestamp = timestamp
            rewriteUpload?(&saved)
            remote = saved
        }
        return RemoteProgress(document: progress.document, timestamp: timestamp)
    }
}
