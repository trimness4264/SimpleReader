import Foundation
import Combine

struct DownloadJob: Identifiable {
    enum State: String { case queued, downloading, importing, finished, failed, cancelled }
    let id: UUID
    let title: String
    let link: OPDSLink
    let credentials: ServerCredentials?
    var state: State = .queued
    var progress: Double = 0
    var error: String?
    var bookID: UUID?
}
@MainActor final class DownloadManager: ObservableObject {
    typealias Transfer = (URLRequest, @escaping (Double) -> Void) async throws -> (URL, HTTPURLResponse)
    struct Actions {
        var canCancel = false
        var canRetry = false
        var bookID: UUID?
    }

    private struct TransferTask {
        let attempt: UUID
        let task: Task<Void, Never>
    }

    @Published private(set) var jobs: [DownloadJob] = []
    private var tasks: [UUID: TransferTask] = [:]
    @Published private var libraryBookIDs: Set<UUID> = []
    private let http: HTTPClient
    private let importer: BookImportService
    private let transfer: Transfer
    init(http: HTTPClient, importer: BookImportService, transfer: Transfer? = nil) {
        self.http = http; self.importer = importer; self.transfer = transfer ?? http.download
        importer.store.$books.map { Set($0.map(\.id)) }
            .removeDuplicates()
            .assign(to: &$libraryBookIDs)
    }
    var activeCount: Int { jobs.filter { [.queued, .downloading, .importing].contains($0.state) }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    var hasHistory: Bool { jobs.contains(where: canClear) }
    func clearHistory() {
        jobs.removeAll(where: canClear)
    }
    private func canClear(_ job: DownloadJob) -> Bool {
        [.finished, .cancelled].contains(job.state) && tasks[job.id] == nil
    }
    private func hasActiveDownload(for link: OPDSLink) -> Bool {
        jobs.contains {
            $0.link.url == link.url && $0.link.type == link.type &&
                ($0.state == .queued || tasks[$0.id] != nil)
        }
    }
    func enqueue(title: String, link: OPDSLink, credentials: ServerCredentials?) {
        guard !hasActiveDownload(for: link) else { return }
        jobs.append(DownloadJob(id: UUID(), title: title, link: link, credentials: credentials)); pump()
    }
    func job(for link: OPDSLink) -> DownloadJob? {
        let matching = jobs.filter { $0.link.url == link.url && $0.link.type == link.type }
        return matching.last { $0.state == .queued || tasks[$0.id] != nil } ?? matching.last
    }
    func actions(for job: DownloadJob) -> Actions {
        switch job.state {
        case .queued, .downloading:
            return Actions(canCancel: true)
        case .failed, .cancelled:
            return Actions(canRetry: !hasActiveDownload(for: job.link))
        case .finished:
            let bookID = job.bookID.flatMap { libraryBookIDs.contains($0) ? $0 : nil }
            return Actions(canRetry: bookID == nil && !hasActiveDownload(for: job.link), bookID: bookID)
        case .importing:
            return Actions()
        }
    }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), actions(for: jobs[index]).canCancel else { return }
        jobs[index].state = .cancelled; tasks[id]?.task.cancel()
        pump()
    }
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), actions(for: jobs[index]).canRetry else { return }
        update(id) { job in
            job.state = .queued
            job.error = nil
            job.progress = 0
            job.bookID = nil
        }
        pump()
    }
    private func update(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }
    private func pump() {
        while tasks.count < 2, let job = jobs.first(where: { $0.state == .queued }) {
            update(job.id) { $0.state = .downloading }
            let attempt = UUID()
            let task = Task {
                defer {
                    tasks[job.id] = nil
                    objectWillChange.send()
                    pump()
                }
                do {
                    var request = try http.request(job.link.url, credentials: job.credentials)
                    request.setValue(job.link.type, forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 600
                    let manager = self
                    let (file, response) = try await transfer(request) { [weak manager] fraction in
                        Task { @MainActor in
                            guard let manager = manager, manager.tasks[job.id]?.attempt == attempt else { return }
                            manager.update(job.id) {
                                if $0.state == .downloading { $0.progress = min(max(fraction, 0), 1) }
                            }
                        }
                    }
                    defer { try? FileManager.default.removeItem(at: file) }
                    try Task.checkCancellation()
                    let contentType = response.mimeType ?? ""
                    guard !contentType.contains("text/html"), !contentType.contains("application/json") else { throw AppFailure("The download returned a sign-in or error page.") }
                    let ext = job.link.type == "application/pdf" ? "pdf" : "epub"
                    var name = (response.suggestedFilename ?? job.link.url.lastPathComponent) as NSString
                    if name.pathExtension.lowercased() != ext { name = "\(name.deletingPathExtension).\(ext)" as NSString }
                    let filename = name.lastPathComponent
                    update(job.id) { $0.state = .importing }
                    let book = try await importer.importBook(from: file, filename: filename)
                    update(job.id) { $0.state = .finished; $0.progress = 1; $0.bookID = book.id }
                } catch {
                    update(job.id) {
                        if $0.state != .cancelled { $0.state = .failed; $0.error = error.localizedDescription }
                    }
                }
            }
            tasks[job.id] = TransferTask(attempt: attempt, task: task)
        }
    }
}
