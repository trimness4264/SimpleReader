import Foundation

struct ServerCredentials {
    let origin: URL
    let username: String
    let password: String
}

enum NetworkPolicy {
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
    static func validate(_ url: URL) throws {
        guard let host = url.host?.lowercased(), url.user == nil, url.password == nil else { throw AppFailure("请输入不含密码的完整服务器地址") }
        if url.scheme?.lowercased() == "https" { return }
        guard url.scheme?.lowercased() == "http", isLocal(host) else { throw AppFailure("公网服务器必须使用 HTTPS；HTTP 仅用于局域网") }
    }
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) {
            return parts[0] == 10 || parts[0] == 127 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1]) || parts[0] == 169 && parts[1] == 254
        }
        let ipv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return ipv6 == "::1" || ipv6.hasPrefix("fc") && ipv6.contains(":") || ipv6.hasPrefix("fd") && ipv6.contains(":") || ipv6.hasPrefix("fe80:")
    }
}

/// A per-task delegate retains origin restrictions across the entire redirect chain.
class CredentialGuard: NSObject, URLSessionTaskDelegate {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? NetworkPolicy.validate(url)) != nil else { completionHandler(nil); return }
        var safe = request
        if !NetworkPolicy.sameOrigin(origin, url) {
            for header in ["Authorization", "X-Auth-User", "X-Auth-Key", "Cookie"] { safe.setValue(nil, forHTTPHeaderField: header) }
        }
        completionHandler(safe)
    }
}
final class TransferDelegate: CredentialGuard, URLSessionDownloadDelegate {
    let progress: (Double) -> Void
    init(origin: URL, progress: @escaping (Double) -> Void) { self.progress = progress; super.init(origin: origin) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}
final class HTTPClient {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }
    func request(_ url: URL, credentials: ServerCredentials? = nil) throws -> URLRequest {
        try NetworkPolicy.validate(url)
        var request = URLRequest(url: url)
        if let credentials = credentials, NetworkPolicy.sameOrigin(credentials.origin, url), !credentials.username.isEmpty {
            request.setValue("Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        return request
    }
    private static func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw AppFailure("服务器响应无效") }
        guard (200...299).contains(response.statusCode) else {
            throw AppFailure(response.statusCode == 401 || response.statusCode == 403 ? "认证失败，请检查账号与密码" : "服务器返回 HTTP \(response.statusCode)")
        }
        return response
    }
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw AppFailure("地址无效") }
        try NetworkPolicy.validate(url)
        let (data, response) = try await session.data(for: request, delegate: CredentialGuard(origin: url))
        return (data, try Self.check(response))
    }
    func download(_ request: URLRequest, progress: @escaping (Double) -> Void) async throws -> (URL, HTTPURLResponse) {
        guard let url = request.url else { throw AppFailure("地址无效") }
        try NetworkPolicy.validate(url)
        let (file, response) = try await session.download(for: request, delegate: TransferDelegate(origin: url, progress: progress))
        do { return (file, try Self.check(response)) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}
