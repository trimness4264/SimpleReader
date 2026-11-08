import Foundation

/// Credential storage is external to the account transaction (Keychain in the app).
struct CredentialStorage {
    var read: (String) throws -> String?
    var write: (String?, String) throws -> Void

    static let keychain = CredentialStorage(read: KeychainService.storedValue, write: { value, key in
        if let value = value { try KeychainService.save(value, key: key) }
        else { try KeychainService.delete(key) }
    })
}

/// Owns account validation, credential keys, and compensation when configuration cannot be saved.
@MainActor final class AccountSettings {
    private let store: LibraryStore
    private let http: HTTPClient
    private let credentialStorage: CredentialStorage
    private let syncKey = "kosync"

    init(store: LibraryStore, http: HTTPClient, credentialStorage: CredentialStorage = .keychain) {
        self.store = store
        self.http = http
        self.credentialStorage = credentialStorage
    }

    func password(for server: OPDSServer) throws -> String {
        try credentialStorage.read(serverKey(server.id)) ?? ""
    }

    func syncPassword() throws -> String { try credentialStorage.read(syncKey) ?? "" }

    func credentials(for server: OPDSServer) throws -> ServerCredentials {
        ServerCredentials(origin: server.url, username: server.username, password: try password(for: server))
    }

    func saveServer(_ server: OPDSServer?, name: String, address: String, username: String, password: String) throws {
        let url = try validatedURL(address, message: "Invalid server address.")
        let record = OPDSServer(id: server?.id ?? UUID(), name: name, url: url, username: username)
        var settings = store.settings
        if let index = settings.servers.firstIndex(where: { $0.id == record.id }) {
            settings.servers[index] = record
        } else {
            settings.servers.append(record)
        }
        try commitCredential(password, key: serverKey(record.id)) {
            try store.saveSettings(settings)
        }
    }

    func deleteServer(_ server: OPDSServer) throws {
        var settings = store.settings
        settings.servers.removeAll { $0.id == server.id }
        try commitCredential(nil, key: serverKey(server.id)) {
            try store.saveSettings(settings)
        }
    }

    func saveSync(address: String, username: String, password: String, enabled: Bool, filenameMatching: Bool) throws {
        let config = try syncConfiguration(address: address, username: username, password: password,
            enabled: enabled, filenameMatching: filenameMatching)
        var settings = store.settings
        let previous = settings.sync
        let changed = previous.url != config.url || previous.username != config.username
            || previous.filenameMatching != config.filenameMatching
        settings.sync = config
        try commitCredential(password, key: syncKey) {
            try store.saveSettings(settings, resettingSyncBaselines: changed)
        }
    }

    func verifySync(address: String, username: String, password: String, enabled: Bool, filenameMatching: Bool) async throws {
        let config = try syncConfiguration(address: address, username: username, password: password,
            enabled: enabled, filenameMatching: filenameMatching)
        try await KOReaderSyncClient(settings: config, password: password, http: http).authorize()
    }

    func syncClient() throws -> KOReaderSyncClient {
        let config = store.settings.sync
        guard !config.username.isEmpty else { throw AppFailure("Set up a KOReader Sync account.") }
        return KOReaderSyncClient(settings: config, password: try syncPassword(), http: http)
    }

    private func serverKey(_ id: UUID) -> String { "opds-\(id)" }

    private func validatedURL(_ address: String, message: String.LocalizationValue) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AppFailure(message) }
        try NetworkPolicy.validate(url)
        return url
    }

    private func syncConfiguration(address: String, username: String, password: String, enabled: Bool, filenameMatching: Bool) throws -> SyncSettings {
        let url = try validatedURL(address, message: "Invalid sync server address.")
        if enabled && (username.isEmpty || password.isEmpty) { throw AppFailure("Enter your username and password before enabling sync.") }
        var config = store.settings.sync
        config.url = url
        config.username = username
        config.enabled = enabled
        config.filenameMatching = filenameMatching
        return config
    }

    private func commitCredential(_ value: String?, key: String, saveConfiguration: () throws -> Void) throws {
        let previous = try credentialStorage.read(key)
        try writeCredential(value, key: key)
        do {
            try saveConfiguration()
        } catch {
            let saveError = error
            do {
                try writeCredential(previous, key: key)
            } catch {
                throw AppFailure("Couldn’t save settings: \(saveError.localizedDescription). Couldn’t restore the previous credentials: \(error.localizedDescription)")
            }
            throw saveError
        }
    }

    private func writeCredential(_ value: String?, key: String) throws {
        try credentialStorage.write(value, key)
    }
}
