import Combine
import Foundation
import Network

/// Schedules KOReader progress for the whole library. Readers decide whether to apply an offer.
@MainActor final class SyncCoordinator: ObservableObject {
    struct RemoteOffer: Equatable {
        let remote: RemoteProgress
        fileprivate let request: Request
        fileprivate let version: SyncLocalVersion
        fileprivate let baseline: String?
        fileprivate let pending: Bool
    }

    enum Outcome { case idle, remote(RemoteOffer), conflict(RemoteOffer), unconfirmed }

    struct ConflictResolution {
        let offer: RemoteOffer
        let isStillValid: @MainActor () -> Bool
    }

    fileprivate struct Request: Equatable {
        let bookID: UUID
        let destination: SyncDestination
        let settingsRevision: UUID
    }

    private struct Job {
        let id: UUID
        let request: Request
        let resolvesConflict: Bool
        let task: Task<JobResult, Error>
    }

    private struct ServerSnapshot {
        let progress: RemoteProgress?
    }

    private struct JobResult {
        let outcome: Outcome
        let snapshot: ServerSnapshot?

        init(outcome: Outcome, snapshot: ServerSnapshot? = nil) {
            self.outcome = outcome
            self.snapshot = snapshot
        }
    }

    @Published private(set) var status = String(localized: "Not synced yet")
    private let store: LibraryStore
    private let makeClient: () throws -> ProgressSyncClient
    private var jobs: [SyncDestination: Job] = [:]
    private var latestRemote: [SyncDestination: RemoteProgress] = [:]
    private var retries: [UUID: Task<Void, Never>] = [:]
    private var settingsUpdates: AnyCancellable?
    private var pathMonitor: NWPathMonitor?
    private var isOnline: Bool?

    init(store: LibraryStore, http: HTTPClient, accounts: AccountSettings? = nil,
         clientFactory: (() throws -> ProgressSyncClient)? = nil) {
        self.store = store
        let accounts = accounts ?? AccountSettings(store: store, http: http)
        makeClient = clientFactory ?? { try accounts.syncClient() }
    }

    deinit {
        pathMonitor?.cancel()
        for task in retries.values { task.cancel() }
    }

    func start() {
        guard pathMonitor == nil else { return }
        settingsUpdates = store.$settings.map(\.sync).removeDuplicates().dropFirst().sink { [weak self] _ in
            // Published settings arrive just before the store updates its value.
            Task { @MainActor in self?.retryPending() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let reconnected = self.isOnline == false && online
                self.isOnline = online
                if reconnected { self.retryPending() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "SimpleReader.SyncNetwork"))
        pathMonitor = monitor
        retryPending()
    }

    func retryPending() {
        for task in retries.values { task.cancel() }
        retries.removeAll()
        guard store.settings.sync.enabled else { return }
        for book in store.books where book.pendingSync {
            scheduleRetry(book.id, delay: .zero)
        }
    }

    func positionDidChange(_ id: UUID) {
        guard pathMonitor != nil, store.settings.sync.enabled, store.book(id)?.pendingSync == true else { return }
        scheduleRetry(id, delay: .seconds(2))
    }

    private func scheduleRetry(_ id: UUID, delay: Duration) {
        guard retries[id] == nil else { return }
        retries[id] = Task { [weak self] in
            defer { if !Task.isCancelled { self?.retries[id] = nil } }
            var delay = delay
            var backoff = Duration.seconds(5)
            while !Task.isCancelled {
                do { try await Task.sleep(for: delay) }
                catch { return }
                guard let self, self.store.settings.sync.enabled, let book = self.store.book(id), book.pendingSync else { return }
                do {
                    let outcome = try await self.synchronize(id, pendingOnly: true)
                    if case .unconfirmed = outcome {
                        // Recheck the server after backoff to distinguish a lost write from a conflict.
                    } else {
                        guard let latest = self.store.book(id), latest.pendingSync,
                              SyncLocalVersion(latest) != SyncLocalVersion(book) else { return }
                        delay = .zero
                        continue
                    }
                } catch {
                    // Transport and persistence failures keep the stored progress eligible for retry.
                }
                delay = backoff
                backoff = min(backoff * 2, .seconds(300))
            }
        }
    }

    func synchronize(_ id: UUID, resolving resolution: ConflictResolution? = nil, pendingOnly: Bool = false) async throws -> Outcome {
        try Task.checkCancellation()
        guard store.settings.sync.enabled, let book = store.book(id), !pendingOnly || book.pendingSync else { return .idle }
        let request = Request(bookID: id, destination: SyncDestination(settings: store.settings.sync, book: book),
            settingsRevision: store.syncSettingsRevision)
        if let resolution, resolution.offer.request != request || !isCurrent(resolution.offer) { return .idle }
        let previous = jobs[request.destination]
        if let previous, previous.request == request, !previous.resolvesConflict, resolution == nil {
            return try await previous.task.value.outcome
        }

        let jobID = UUID()
        let task = Task { @MainActor () async throws -> JobResult in
            var snapshot: ServerSnapshot?
            if let previous {
                let result = try? await previous.task.value
                if resolution == nil, previous.request.settingsRevision == request.settingsRevision {
                    snapshot = result?.snapshot
                }
            }
            defer {
                if jobs[request.destination]?.id == jobID { jobs[request.destination] = nil }
            }
            do {
                return try await perform(request, resolving: resolution, snapshot: snapshot)
            } catch {
                if request.settingsRevision == store.syncSettingsRevision { status = error.localizedDescription }
                throw error
            }
        }
        jobs[request.destination] = Job(id: jobID, request: request, resolvesConflict: resolution != nil, task: task)
        return try await task.value.outcome
    }

    private func currentBook(for request: Request) throws -> Book? {
        guard request.settingsRevision == store.syncSettingsRevision else { throw AppFailure("Sync settings changed. Try again.") }
        guard let book = store.book(request.bookID), SyncDestination(settings: store.settings.sync, book: book) == request.destination else { return nil }
        return book
    }

    private func perform(_ request: Request, resolving resolution: ConflictResolution?, snapshot: ServerSnapshot?) async throws -> JobResult {
        guard try currentBook(for: request) != nil else { return JobResult(outcome: .idle, snapshot: snapshot) }
        let client = try makeClient()
        let document = request.destination.document
        var resolution = resolution
        var snapshot = snapshot

        while true {
            let remote: RemoteProgress?
            if let snapshot { remote = snapshot.progress }
            else { remote = try await client.get(document: document) }
            let observed = ServerSnapshot(progress: remote)
            snapshot = nil
            let current = try currentBook(for: request)
            latestRemote[request.destination] = remote
            guard var book = current else { return JobResult(outcome: .idle, snapshot: observed) }
            if let resolution, !resolution.isStillValid() { return JobResult(outcome: .idle, snapshot: observed) }
            let forceUpload = resolution.map { isCurrent($0.offer) } ?? false
            resolution = nil

            if let upload = book.syncUpload, upload.destination == request.destination {
                if let remote, upload.confirms(remote) {
                    if try confirm(upload, remote: remote, book: book) { continue }
                    return JobResult(outcome: .idle, snapshot: observed)
                }
                book.syncUpload = nil
                try store.save(book)
            }

            switch SyncPolicy.decide(book: book, remote: remote, resolvingConflict: forceUpload) {
            case .unchanged:
                status = String(localized: "Reading positions match")
                return JobResult(outcome: .idle, snapshot: observed)
            case .download(let remote):
                status = String(localized: "Remote progress found")
                return JobResult(outcome: .remote(offer(remote, request: request, book: book)), snapshot: observed)
            case .conflict(let remote):
                status = String(localized: "Choose a reading position to sync")
                return JobResult(outcome: .conflict(offer(remote, request: request, book: book)), snapshot: observed)
            case .missingUploadPosition:
                status = book.format == .epub
                    ? String(localized: "Couldn’t convert the EPUB position. Your local progress was saved and uploads are paused.")
                    : String(localized: "Invalid local reading progress.")
                return JobResult(outcome: .idle, snapshot: observed)
            case .upload(let position):
                if let result = try await send(position, book: book, request: request, previous: remote, client: client) {
                    return result
                }
            }
        }
    }

    /// A nil result means an upload was confirmed and a newer local position is still pending.
    private func send(_ position: SyncPolicy.UploadPosition, book: Book, request: Request, previous: RemoteProgress?,
                      client: ProgressSyncClient) async throws -> JobResult? {
        let document = request.destination.document
        var upload = SyncUpload(destination: request.destination, version: SyncLocalVersion(book), previous: previous,
            expected: RemoteProgress(document: document, progress: position.pointer, percentage: position.percentage,
                device: "Simple Reader", device_id: store.settings.sync.deviceID))
        var book = book
        book.syncUpload = upload
        try store.save(book)
        latestRemote[request.destination] = nil
        let receipt = try await client.put(upload.expected)
        guard var latest = try currentBook(for: request), latest.syncUpload == upload else { return JobResult(outcome: .idle) }
        guard (receipt.document ?? document) == document else { return try rejectUpload(latest) }
        if let timestamp = receipt.timestamp {
            upload.expected.timestamp = timestamp
            latest.syncUpload = upload
            try store.save(latest)
        }

        let confirmed = try await client.get(document: document)
        let current = try currentBook(for: request)
        latestRemote[request.destination] = confirmed
        guard let latest = current, latest.syncUpload == upload else {
            return JobResult(outcome: .idle, snapshot: ServerSnapshot(progress: confirmed))
        }
        guard let confirmed, upload.confirms(confirmed) else { return try rejectUpload(latest) }
        if try confirm(upload, remote: confirmed, book: latest) { return nil }
        return JobResult(outcome: .idle, snapshot: ServerSnapshot(progress: confirmed))
    }

    private func rejectUpload(_ book: Book) throws -> JobResult {
        var book = book
        book.syncUpload = nil
        try store.save(book)
        status = String(localized: "The remote position changed. Local progress is still waiting to sync.")
        return JobResult(outcome: .unconfirmed)
    }

    private func confirm(_ upload: SyncUpload, remote: RemoteProgress, book: Book) throws -> Bool {
        var updated = book
        updated.syncUpload = nil
        updated.remoteBaseline = remote.fingerprint
        if SyncLocalVersion(book) == upload.version { updated.pendingSync = false }
        try store.save(updated)
        status = String(localized: "Sync complete")
        return updated.pendingSync
    }

    private func offer(_ remote: RemoteProgress, request: Request, book: Book) -> RemoteOffer {
        RemoteOffer(remote: remote, request: request, version: SyncLocalVersion(book), baseline: book.remoteBaseline, pending: book.pendingSync)
    }

    func isCurrent(_ offer: RemoteOffer) -> Bool {
        guard let book = try? currentBook(for: offer.request) else { return false }
        return latestRemote[offer.request.destination] == offer.remote && SyncLocalVersion(book) == offer.version
            && book.remoteBaseline == offer.baseline && book.pendingSync == offer.pending
    }

    func acceptRemote(_ offer: RemoteOffer, position: ReadingPosition) throws {
        guard isCurrent(offer), var book = store.book(offer.request.bookID) else { throw CancellationError() }
        book.position = position
        book.pendingSync = false
        book.remoteBaseline = offer.remote.fingerprint
        book.syncUpload = nil
        try store.save(book)
        status = String(localized: "Received remote progress")
    }
}
