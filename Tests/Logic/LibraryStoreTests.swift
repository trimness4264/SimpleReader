import XCTest
@testable import SimpleReader

@MainActor final class LibraryStoreTests: XCTestCase {
    func testPendingProgressAndDeviceIdentitySurviveReload() async throws {
        let store = try library(inMemory: false)
        var book = sampleBook()
        book.pendingSync = true
        try store.save(book)

        let reloaded = try LibraryStore(root: store.root)

        XCTAssertEqual(reloaded.book(book.id), book)
        XCTAssertEqual(reloaded.settings.sync.deviceID, store.settings.sync.deviceID)
    }

    func testFailedSettingsTransactionPreservesBaselinesAndSettings() async throws {
        let store = try library(inMemory: false)
        var book = sampleBook()
        book.remoteBaseline = "confirmed-position"
        try store.save(book)
        let oldFontSize = store.settings.reader.fontSize
        var invalid = store.settings
        invalid.reader.fontSize = .nan // JSON cannot encode this, after book changes have been staged.

        XCTAssertThrowsError(try store.saveSettings(invalid, resettingSyncBaselines: true))

        // A later successful save must not accidentally commit the failed transaction.
        try store.saveSettings(store.settings)
        let reloaded = try LibraryStore(root: store.root)
        XCTAssertEqual(store.book(book.id), book)
        XCTAssertEqual(reloaded.book(book.id), book)
        XCTAssertEqual(store.settings.reader.fontSize, oldFontSize)
        XCTAssertEqual(reloaded.settings.reader.fontSize, oldFontSize)
    }

    func testDeletingSelectedBooksPreservesUnselectedBookAndFilesAfterReload() async throws {
        let store = try library(inMemory: false)
        let removed = sampleBook()
        let retained = sampleBook()
        for book in [removed, retained] {
            try Data("book".utf8).write(to: store.fileURL(book.filePath))
            try store.save(book)
        }

        try store.delete([removed, removed])

        let reloaded = try LibraryStore(root: store.root)
        XCTAssertEqual(reloaded.books, [retained])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(removed.filePath).path))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(retained.filePath)), Data("book".utf8))
    }
}
