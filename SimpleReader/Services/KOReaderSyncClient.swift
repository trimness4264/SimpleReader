import Foundation

protocol ProgressSyncClient {
    func get(document: String) async throws -> RemoteProgress?
    func put(_ progress: RemoteProgress) async throws -> RemoteProgress
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
        var request = try request(path: "syncs/progress/\(document)")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, _) = try await http.data(request)
        let progress = try JSONDecoder().decode(RemoteProgress.self, from: data)
        guard let percentage = progress.percentage else { return nil }
        guard (progress.document ?? document) == document, (0...1).contains(percentage),
              let pointer = progress.progress, !pointer.isEmpty else {
            throw AppFailure("The server returned an invalid reading position.")
        }
        return progress
    }
    func put(_ progress: RemoteProgress) async throws -> RemoteProgress {
        var request = try request(path: "syncs/progress", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(progress)
        let (data, _) = try await http.data(request)
        // The reference server returns the document and the timestamp it wrote.
        return data.isEmpty ? RemoteProgress() : try JSONDecoder().decode(RemoteProgress.self, from: data)
    }
}
