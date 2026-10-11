import Foundation
import WebKit
import ReadiumShared

@MainActor final class ContinuousPublicationServer: NSObject, WKURLSchemeHandler {
    let scheme = "simple-reader-book"
    let baseURL: URL
    private let publication: Publication
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(publication: Publication) {
        self.publication = publication
        baseURL = URL(string: "simple-reader-book://\(UUID().uuidString.lowercased())/")!
        super.init()
    }
    func url(for href: String) -> URL { URL(string: href, relativeTo: baseURL)!.absoluteURL }
    func close() { for task in tasks.values { task.cancel() }; tasks.removeAll() }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        tasks[key] = Task { [weak self] in
            guard let self = self, let url = urlSchemeTask.request.url, url.host == self.baseURL.host else { return }
            do {
                let path = (URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let data: Data
                let mime: String
                if path.hasPrefix("_reader/fonts/") {
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    guard let file = Bundle.main.url(forResource: String(name.dropLast(4)), withExtension: "ttf", subdirectory: "Fonts") else { throw AppFailure("阅读字体缺失") }
                    data = try Data(contentsOf: file)
                    mime = "font/ttf"
                } else {
                    guard let href = AnyURL(string: path), let resource = self.publication.get(href) else { throw AppFailure("图书资源不存在：\(path)") }
                    data = try await resource.read().get()
                    let properties = try? await resource.properties().get()
                    mime = self.publication.linkWithHREF(href)?.mediaType?.string ?? properties?.mediaType?.string ?? "application/octet-stream"
                }
                guard !Task.isCancelled, self.tasks[key] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled, self.tasks[key] != nil { urlSchemeTask.didFailWithError(error) }
            }
            self.tasks.removeValue(forKey: key)
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}
