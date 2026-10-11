import Foundation

struct DownloadJob: Identifiable {
    enum State: String { case queued, downloading, importing, finished, failed, cancelled }
    let id: UUID
    let title: String
    let link: OPDSLink
    let credentials: ServerCredentials?
    var state: State = .queued
    var progress: Double = 0
    var error: String?
}
@MainActor final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let http: HTTPClient
    private let importer: BookImportService
    init(http: HTTPClient, importer: BookImportService) { self.http = http; self.importer = importer }
    var activeCount: Int { jobs.filter { [.queued, .downloading, .importing].contains($0.state) }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    var hasHistory: Bool { jobs.contains { [.finished, .cancelled].contains($0.state) } }
    func clearHistory() {
        jobs.removeAll { [.finished, .cancelled].contains($0.state) }
    }
    func enqueue(title: String, link: OPDSLink, credentials: ServerCredentials?) {
        guard !jobs.contains(where: { $0.link.url == link.url && [.queued, .downloading, .importing].contains($0.state) }) else { return }
        jobs.append(DownloadJob(id: UUID(), title: title, link: link, credentials: credentials)); pump()
    }
    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), [.queued, .downloading].contains(jobs[index].state) else { return }
        jobs[index].state = .cancelled; tasks[id]?.cancel()
        pump()
    }
    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(jobs[index].state), tasks[id] == nil else { return }
        jobs[index].state = .queued; jobs[index].error = nil; jobs[index].progress = 0; pump()
    }
    private func update(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        if let index = jobs.firstIndex(where: { $0.id == id }) { change(&jobs[index]) }
    }
    private func pump() {
        while tasks.count < 2, let job = jobs.first(where: { $0.state == .queued }) {
            update(job.id) { $0.state = .downloading }
            tasks[job.id] = Task {
                defer { tasks[job.id] = nil; pump() }
                do {
                    var request = try http.request(job.link.url, credentials: job.credentials)
                    request.timeoutInterval = 600
                    let manager = self
                    let (file, response) = try await http.download(request) { [weak manager] fraction in
                        Task { @MainActor in manager?.update(job.id) { $0.progress = fraction } }
                    }
                    defer { try? FileManager.default.removeItem(at: file) }
                    try Task.checkCancellation()
                    let contentType = response.mimeType ?? ""
                    guard !contentType.contains("text/html"), !contentType.contains("application/json") else { throw AppFailure("下载返回了登录页或错误页") }
                    let ext = job.link.type == "application/pdf" ? "pdf" : "epub"
                    var name = (response.suggestedFilename ?? job.link.url.lastPathComponent) as NSString
                    if name.pathExtension.lowercased() != ext { name = "\(name.deletingPathExtension).\(ext)" as NSString }
                    let filename = name.lastPathComponent
                    update(job.id) { $0.state = .importing }
                    _ = try await importer.importBook(from: file, filename: filename)
                    update(job.id) { $0.state = .finished; $0.progress = 1 }
                } catch {
                    update(job.id) {
                        if $0.state != .cancelled { $0.state = .failed; $0.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
