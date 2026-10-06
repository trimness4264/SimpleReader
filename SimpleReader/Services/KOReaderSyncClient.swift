import Foundation

protocol ProgressSyncClient {
    func get(document: String) async throws -> RemoteProgress?
    func put(document: String, position: ReadingPosition, deviceID: String) async throws
}
final class KOReaderSyncClient: ProgressSyncClient {
    let settings: SyncSettings
    private let userkey: String
    private let http: HTTPClient
    init(settings: SyncSettings, password: String, http: HTTPClient) {
        self.settings = settings; self.http = http; userkey = BookHashing.md5(Data(password.utf8))
    }
    private func request(path: String, method: String = "GET") throws -> URLRequest {
        let url = settings.url.appendingPathComponent(path)
        var request = try http.request(url)
        request.httpMethod = method
        request.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
        request.setValue(settings.username, forHTTPHeaderField: "X-Auth-User")
        request.setValue(userkey, forHTTPHeaderField: "X-Auth-Key")
        return request
    }
    func authorize() async throws { _ = try await http.data(request(path: "users/auth")) }
    func get(document: String) async throws -> RemoteProgress? {
        let (data, _) = try await http.data(request(path: "syncs/progress/\(document)"))
        let progress = try JSONDecoder().decode(RemoteProgress.self, from: data)
        guard let percentage = progress.percentage else { return nil }
        guard percentage.isFinite, (0...1).contains(percentage), let pointer = progress.progress, !pointer.isEmpty else { throw AppFailure("服务器阅读位置无效") }
        return progress
    }
    func put(document: String, position: ReadingPosition, deviceID: String) async throws {
        let pointer: String
        if let page = position.pdfPage { pointer = String(page + 1) }
        else if let xpointer = position.xpointer, xpointer.hasPrefix("/body/DocFragment") { pointer = xpointer }
        else { throw AppFailure("EPUB 位置转换失败，已保留本地进度并暂停上传") }
        guard position.progression.isFinite, (0...1).contains(position.progression) else { throw AppFailure("本地阅读进度无效") }
        var request = try request(path: "syncs/progress", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["document": document, "progress": pointer, "percentage": position.progression, "device": "Simple Reader", "device_id": deviceID])
        _ = try await http.data(request)
    }
}

enum SyncDecision: Equatable {
    case unchanged
    case pull(RemoteProgress)
    case push
    case conflict(RemoteProgress)
    static func decide(book: Book, remote: RemoteProgress?) -> SyncDecision {
        guard let remote = remote else { return book.pendingSync && book.position != nil ? .push : .unchanged }
        if book.pendingSync {
            return remote.fingerprint == book.remoteBaseline ? .push : .conflict(remote)
        }
        return remote.fingerprint == book.remoteBaseline ? .unchanged : .pull(remote)
    }
}
@MainActor final class SyncCoordinator: ObservableObject {
    enum Outcome { case idle, remote(RemoteProgress), conflict(RemoteProgress) }
    @Published private(set) var status = "尚未同步"
    private let store: LibraryStore
    private let http: HTTPClient
    private var active: Set<UUID> = []
    private let clientFactory: (() throws -> ProgressSyncClient)?
    init(store: LibraryStore, http: HTTPClient, clientFactory: (() throws -> ProgressSyncClient)? = nil) { self.store = store; self.http = http; self.clientFactory = clientFactory }
    func makeClient() throws -> KOReaderSyncClient {
        let config = store.settings.sync
        guard !config.username.isEmpty else { throw AppFailure("请设置 KOReader Sync 账号") }
        return KOReaderSyncClient(settings: config, password: try KeychainService.read("kosync"), http: http)
    }
    func document(_ book: Book) -> String { store.settings.sync.filenameMatching ? book.identity.filenameMD5 : book.identity.partialMD5 }
    func synchronize(_ id: UUID, preferLocal: Bool = false) async throws -> Outcome {
        guard store.settings.sync.enabled, !active.contains(id) else { return .idle }
        active.insert(id); defer { active.remove(id) }
        do {
            let client: ProgressSyncClient = try clientFactory?() ?? makeClient()
            guard let initial = store.book(id) else { return .idle }
            let configuration = store.settings.sync
            let identity = document(initial)
            let remote = try await client.get(document: identity)
            guard store.settings.sync.url == configuration.url, store.settings.sync.username == configuration.username, store.settings.sync.filenameMatching == configuration.filenameMatching, store.settings.sync.enabled else { throw AppFailure("同步设置已改变，请重试") }
            guard let book = store.book(id) else { return .idle }
            let decision = SyncDecision.decide(book: book, remote: remote)
            if !preferLocal {
                switch decision {
                case .pull(let value): status = "发现远端进度"; return .remote(value)
                case .conflict(let value): status = "需要选择同步位置"; return .conflict(value)
                case .unchanged: status = "进度一致"; return .idle
                case .push: break
                }
            }
            guard let snapshot = book.position else { return .idle }
            try await client.put(document: identity, position: snapshot, deviceID: store.settings.sync.deviceID)
            let confirmed = try await client.get(document: identity)
            let expected = snapshot.pdfPage.map { String($0+1) } ?? snapshot.xpointer
            guard let confirmed = confirmed, confirmed.progress == expected else {
                status = "远端位置已变化，本地仍待同步"; return .idle
            }
            guard store.settings.sync.url == configuration.url, store.settings.sync.username == configuration.username, store.settings.sync.filenameMatching == configuration.filenameMatching else { throw AppFailure("同步设置已改变，请重试") }
            guard var latest = store.book(id) else { return .idle }
            latest.remoteBaseline = confirmed.fingerprint
            if latest.position == snapshot { latest.pendingSync = false }
            try store.save(latest)
            status = "同步完成"; return .idle
        } catch { status = error.localizedDescription; throw error }
    }
    func acceptRemote(_ remote: RemoteProgress, id: UUID, position: ReadingPosition) throws {
        guard var book = store.book(id) else { return }
        book.position = position; book.pendingSync = false; book.remoteBaseline = remote.fingerprint
        try store.save(book); status = "已接收远端进度"
    }
}
