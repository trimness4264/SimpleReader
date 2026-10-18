import Foundation

struct OPDSLink: Hashable {
    let url: URL
    let rel: String
    let type: String
    var isAcquisition: Bool { rel.hasPrefix("http://opds-spec.org/acquisition") && ["application/epub+zip", "application/pdf"].contains(type) }
}
struct OPDSEntry: Identifiable {
    var id: String
    var title: String
    var author: String
    var summary: String
    var links: [OPDSLink]
    var downloads: [OPDSLink] { links.filter(\.isAcquisition) }
    var navigation: OPDSLink? { links.first { $0.type.contains("application/atom+xml") && !$0.rel.hasPrefix("http://opds-spec.org/acquisition") } }
    var cover: URL? { links.first { $0.rel == "http://opds-spec.org/image/thumbnail" }?.url ?? links.first { $0.rel == "http://opds-spec.org/image" }?.url }
}
struct OPDSCatalog {
    var title: String
    var entries: [OPDSEntry]
    var links: [OPDSLink]
    var next: URL? { links.first { $0.rel == "next" }?.url }
    var search: OPDSLink? { links.first { $0.rel == "search" } }
}

final class OPDSParser: NSObject, XMLParserDelegate {
    private var catalog = OPDSCatalog(title: "目录", entries: [], links: [])
    private var entry: OPDSEntry?
    private var stack: [String] = []
    private var texts: [String] = []
    private var bases: [URL] = []
    private let base: URL
    init(base: URL) { self.base = base }
    static func parse(_ data: Data, base: URL) throws -> OPDSCatalog {
        let delegate = OPDSParser(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.stack.isEmpty, delegate.sawFeed else { throw AppFailure("不是有效的 OPDS 1.x 目录") }
        return delegate.catalog
    }
    private var sawFeed = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let parentBase = bases.last ?? base
        let currentBase = attributes["xml:base"].flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase
        bases.append(currentBase); stack.append(elementName); texts.append("")
        if elementName == "feed", namespaceURI == "http://www.w3.org/2005/Atom" { sawFeed = true }
        if elementName == "entry" { entry = OPDSEntry(id: UUID().uuidString, title: "未命名图书", author: "", summary: "", links: []) }
        if elementName == "link", let href = attributes["href"], let url = URL(string: href, relativeTo: currentBase)?.absoluteURL {
            let link = OPDSLink(url: url, rel: attributes["rel"] ?? "alternate", type: (attributes["type"] ?? "").components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces))
            if entry != nil { entry?.links.append(link) } else { catalog.links.append(link) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !texts.isEmpty { texts[texts.count - 1] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let text = (texts.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        stack.removeLast()
        bases.removeLast()
        switch (elementName, stack.last) {
        case ("title", "entry"):
            entry?.title = text
        case ("title", "feed"):
            catalog.title = text
        case ("id", "entry"):
            entry?.id = text
        case ("name", "author"):
            if var entry = entry {
                entry.author += (entry.author.isEmpty ? "" : ", ") + text
                self.entry = entry
            }
        case ("summary", "entry"), ("content", "entry"):
            entry?.summary = text
        case ("entry", _):
            if let complete = entry { catalog.entries.append(complete) }
            entry = nil
        default:
            break
        }
        if !texts.isEmpty { texts[texts.count - 1] += text }
    }
}

final class OPDSClient {
    private let http: HTTPClient
    init(http: HTTPClient) { self.http = http }
    func load(_ url: URL, credentials: ServerCredentials?) async throws -> OPDSCatalog {
        let (data, response) = try await http.data(http.request(url, credentials: credentials))
        return try OPDSParser.parse(data, base: response.url ?? url)
    }
    func searchURL(link: OPDSLink, query: String, credentials: ServerCredentials?) async throws -> URL {
        var template = link.url.absoluteString.replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive).replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
        if link.type.contains("opensearchdescription") {
            let (data, response) = try await http.data(http.request(link.url, credentials: credentials))
            let parser = OpenSearchParser(base: response.url ?? link.url)
            let xml = XMLParser(data: data); xml.shouldProcessNamespaces = true; xml.delegate = parser
            guard xml.parse(), let found = parser.template else { throw AppFailure("服务器没有支持的搜索模板") }
            template = found
        }
        guard template.contains("{searchTerms}") || template.contains("{searchTerms?}") else { throw AppFailure("服务器没有支持的搜索模板") }
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+#?/")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        template = template.replacingOccurrences(of: "{searchTerms}", with: encoded).replacingOccurrences(of: "{searchTerms?}", with: encoded)
        for (key, value) in [("{startPage?}", "1"), ("{startIndex?}", "0"), ("{count?}", "50"), ("{language?}", ""), ("{inputEncoding?}", "UTF-8"), ("{outputEncoding?}", "UTF-8")] { template = template.replacingOccurrences(of: key, with: value) }
        guard !template.contains("{"), let url = URL(string: template) else { throw AppFailure("不支持这个搜索模板") }
        return url
    }
}
private final class OpenSearchParser: NSObject, XMLParserDelegate {
    let base: URL
    var template: String?
    init(base: URL) { self.base = base }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "Url", attributes["type"]?.contains("application/atom+xml") == true, let raw = attributes["template"] {
            // Preserve braces for substitution; URL would escape them.
            template = raw.hasPrefix("http") ? raw : URL(string: raw, relativeTo: base)?.absoluteString.replacingOccurrences(of: "%7B", with: "{", options: .caseInsensitive).replacingOccurrences(of: "%7D", with: "}", options: .caseInsensitive)
        }
    }
}
