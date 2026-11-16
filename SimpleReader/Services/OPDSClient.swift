import Foundation
import SwiftSoup

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

private struct OPDSDescription {
    private enum Format {
        case text, html, xhtml

        init(type: String) {
            switch type.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() {
            case "html", "text/html": self = .html
            case "xhtml", "application/xhtml+xml": self = .xhtml
            default: self = .text
            }
        }
    }

    private let format: Format
    private let isContent: Bool
    private var depth = 0
    private var source = ""

    init(type: String, isContent: Bool) {
        format = Format(type: type)
        self.isContent = isContent
    }

    mutating func startChild(_ elementName: String) {
        depth += 1
        if format != .text { source += "<\(elementName)>" }
    }

    mutating func appendCharacters(_ text: String) {
        source += format == .xhtml ? Entities.escape(text) : text
    }

    // Returns true when the description element itself closes.
    mutating func endElement(_ elementName: String) -> Bool {
        guard depth > 0 else { return true }
        depth -= 1
        if format != .text, elementName != "br" { source += "</\(elementName)>" }
        return false
    }

    func plainText(isCalibreWeb: Bool) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard format != .text, let body = try? SwiftSoup.parseBodyFragment(trimmed).body() else { return trimmed }
        if isCalibreWeb, isContent, format == .xhtml {
            Self.decodeCalibreWebComment(in: body)
        }
        var result = ""
        Self.appendText(from: body, to: &result)
        return result
            .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeCalibreWebComment(in body: Element) {
        // The feed template places its escaped comment in the final paragraph of the XHTML wrapper.
        let children = body.children()
        guard children.size() == 1, let wrapper = children.first(), wrapper.tagName() == "div",
              let paragraph = wrapper.children().last(), paragraph.tagName() == "p",
              paragraph.childNodeSize() == 1, let text = paragraph.childNode(0) as? TextNode,
              let comment = try? SwiftSoup.parseBodyFragment(text.getWholeText()).body(),
              !comment.children().isEmpty() else { return }
        try? text.replaceWith(comment)
    }

    private static func appendText(from node: Node, to result: inout String) {
        if let textNode = node as? TextNode {
            result += textNode.getWholeText().replacingOccurrences(of: #"[\t\r\n\f]+"#, with: " ", options: .regularExpression)
            return
        }

        guard let element = node as? Element else { return }
        let separator: String
        switch element.tagName() {
        case "script", "style", "template", "head": return
        case "br": result += "\n"; return
        case "p": separator = "\n\n"
        default: separator = element.isBlock() ? "\n" : ""
        }
        result += separator
        for child in element.getChildNodes() {
            appendText(from: child, to: &result)
        }
        result += separator
    }
}

final class OPDSParser: NSObject, XMLParserDelegate {
    private static let atomNamespace = "http://www.w3.org/2005/Atom"
    private static let calibreWebFeedID = "urn:uuid:2853dacf-ed79-42f5-8e8a-a7bb3d1ae6a2"
    private var catalog = OPDSCatalog(title: String(localized: "Contents"), entries: [], links: [])
    private var entry: OPDSEntry?
    private var stack: [String] = []
    private var texts: [String] = []
    private var bases: [URL] = []
    private var bookDescription: OPDSDescription?
    private var descriptions: [Int: OPDSDescription] = [:]
    private var isCalibreWeb = false
    private let base: URL
    init(base: URL) { self.base = base }
    static func parse(_ data: Data, base: URL) throws -> OPDSCatalog {
        let delegate = OPDSParser(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.stack.isEmpty, delegate.sawFeed else { throw AppFailure("Invalid OPDS 1.x catalog.") }
        // Atom allows the feed ID to appear after the entries.
        for index in delegate.catalog.entries.indices {
            if let description = delegate.descriptions[index] {
                delegate.catalog.entries[index].summary = description.plainText(isCalibreWeb: delegate.isCalibreWeb)
            }
        }
        return delegate.catalog
    }
    private var sawFeed = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if bookDescription != nil {
            bookDescription?.startChild(elementName)
            return
        }
        if stack.last == "entry", elementName == "summary" || elementName == "content" {
            bookDescription = OPDSDescription(type: attributes["type"] ?? "text", isContent: elementName == "content")
            return
        }
        let parentBase = bases.last ?? base
        let currentBase = attributes["xml:base"].flatMap { URL(string: $0, relativeTo: parentBase)?.absoluteURL } ?? parentBase
        bases.append(currentBase); stack.append(elementName); texts.append("")
        if elementName == "feed", namespaceURI == Self.atomNamespace { sawFeed = true }
        if elementName == "entry" { entry = OPDSEntry(id: UUID().uuidString, title: String(localized: "Untitled Book"), author: "", summary: "", links: []) }
        if elementName == "link", let href = attributes["href"], let url = URL(string: href, relativeTo: currentBase)?.absoluteURL {
            let link = OPDSLink(url: url, rel: attributes["rel"] ?? "alternate", type: (attributes["type"] ?? "").components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces))
            if entry != nil { entry?.links.append(link) } else { catalog.links.append(link) }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if bookDescription != nil {
            bookDescription?.appendCharacters(string)
        } else if !texts.isEmpty {
            texts[texts.count - 1] += string
        }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if bookDescription != nil {
            if bookDescription?.endElement(elementName) == true {
                if entry != nil { descriptions[catalog.entries.count] = bookDescription }
                bookDescription = nil
            }
            return
        }
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
        case ("id", "feed") where stack.count == 1 && namespaceURI == Self.atomNamespace:
            isCalibreWeb = text.caseInsensitiveCompare(Self.calibreWebFeedID) == .orderedSame
        case ("name", "author"):
            if var entry = entry {
                entry.author += (entry.author.isEmpty ? "" : ", ") + text
                self.entry = entry
            }
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
            guard xml.parse(), let found = parser.template else { throw AppFailure("The server has no supported search template.") }
            template = found
        }
        guard template.contains("{searchTerms}") || template.contains("{searchTerms?}") else { throw AppFailure("The server has no supported search template.") }
        var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+#?/")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        template = template.replacingOccurrences(of: "{searchTerms}", with: encoded).replacingOccurrences(of: "{searchTerms?}", with: encoded)
        for (key, value) in [("{startPage?}", "1"), ("{startIndex?}", "0"), ("{count?}", "50"), ("{language?}", ""), ("{inputEncoding?}", "UTF-8"), ("{outputEncoding?}", "UTF-8")] { template = template.replacingOccurrences(of: key, with: value) }
        guard !template.contains("{"), let url = URL(string: template) else { throw AppFailure("Unsupported search template.") }
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
