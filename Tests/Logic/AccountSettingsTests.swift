import XCTest
@testable import SimpleReader

@MainActor final class AccountSettingsTests: XCTestCase {
    func testSwitchingSyncAccountClearsBaselinesWithoutLosingPendingProgress() async throws {
        let store = try library(inMemory: false)
        var book = sampleBook()
        book.remoteBaseline = "old-account-position"
        book.pendingSync = true
        try store.save(book)
        let credentials = MemoryCredentials()
        let accounts = AccountSettings(store: store, http: HTTPClient(), credentialStorage: credentials.storage)

        try accounts.saveSync(address: "https://sync.example.com", username: "new-account",
            password: "new-password", enabled: true, filenameMatching: false)

        let reloaded = try LibraryStore(root: store.root)
        XCTAssertEqual(reloaded.settings.sync.username, "new-account")
        XCTAssertNil(reloaded.book(book.id)?.remoteBaseline)
        XCTAssertEqual(reloaded.book(book.id)?.position, book.position)
        XCTAssertEqual(reloaded.book(book.id)?.pendingSync, true)
        XCTAssertEqual(try accounts.syncPassword(), "new-password")
    }

    func testChangingOnlyPasswordKeepsSyncBaseline() async throws {
        let store = try library()
        var settings = store.settings
        settings.sync.username = "reader"
        try store.saveSettings(settings)
        var book = sampleBook()
        book.remoteBaseline = "same-account-position"
        try store.save(book)
        let accounts = AccountSettings(store: store, http: HTTPClient(), credentialStorage: MemoryCredentials().storage)

        try accounts.saveSync(address: settings.sync.url.absoluteString, username: "reader",
            password: "replacement", enabled: true, filenameMatching: false)

        XCTAssertEqual(store.book(book.id)?.remoteBaseline, "same-account-position")
    }

    func testCredentialWriteFailureKeepsPreviousServerAndPassword() async throws {
        let store = try library()
        let credentials = MemoryCredentials()
        let accounts = AccountSettings(store: store, http: HTTPClient(), credentialStorage: credentials.storage)
        try accounts.saveServer(nil, name: "Original", address: "https://books.example.com", username: "reader", password: "old")
        let original = try XCTUnwrap(store.settings.servers.first)
        credentials.rejectWrites = true

        XCTAssertThrowsError(try accounts.saveServer(original, name: "Changed", address: "https://new.example.com", username: "other", password: "new"))

        XCTAssertEqual(store.settings.servers, [original])
        XCTAssertEqual(try accounts.password(for: original), "old")
    }

    func testChangingDocumentMatchingClearsPreviousSyncBaseline() async throws {
        let store = try library()
        var book = sampleBook()
        book.remoteBaseline = "content-matched-position"
        try store.save(book)
        let accounts = AccountSettings(store: store, http: HTTPClient(), credentialStorage: MemoryCredentials().storage)

        try accounts.saveSync(address: store.settings.sync.url.absoluteString, username: "", password: "",
            enabled: false, filenameMatching: true)

        XCTAssertTrue(store.settings.sync.filenameMatching)
        XCTAssertNil(store.book(book.id)?.remoteBaseline)
    }

    func testInvalidSyncConfigurationDoesNotReplaceSavedCredentials() async throws {
        let store = try library()
        let accounts = AccountSettings(store: store, http: HTTPClient(), credentialStorage: MemoryCredentials().storage)
        try accounts.saveSync(address: "https://sync.example.com", username: "reader", password: "old", enabled: true, filenameMatching: false)

        XCTAssertThrowsError(try accounts.saveSync(address: "https://sync.example.com", username: "", password: "new", enabled: true, filenameMatching: false))

        XCTAssertEqual(store.settings.sync.username, "reader")
        XCTAssertEqual(try accounts.syncPassword(), "old")
    }
}

private final class MemoryCredentials {
    private var values: [String: String] = [:]
    var rejectWrites = false
    var storage: CredentialStorage {
        CredentialStorage(read: { self.values[$0] }, write: { value, key in
            if self.rejectWrites { throw AppFailure("Credential storage unavailable") }
            self.values[key] = value
        })
    }
}
