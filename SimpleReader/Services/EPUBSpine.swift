import Foundation

/// Readium's readingOrder excludes linear="no" items; KOReader's DocFragment
/// numbering follows the original OPF spine, including those items.
final class EPUBSpineParser: NSObject, XMLParserDelegate {
    var rootfile: String?
    var manifest: [String: String] = [:]
    var references: [String] = []
    private var stack: [String] = []
    static func parse(_ data: Data) throws -> EPUBSpineParser {
        let delegate = EPUBSpineParser()
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.delegate = delegate
        guard parser.parse() else { throw AppFailure("无法读取 EPUB 原始章节顺序") }
        return delegate
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "rootfile", rootfile == nil { rootfile = attributes["full-path"] }
        if elementName == "item", stack.last == "manifest", let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        if elementName == "itemref", stack.last == "spine", let id = attributes["idref"] { references.append(id) }
        stack.append(elementName)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { stack.removeLast() }
    func hrefs(relativeTo opf: String) throws -> [String] {
        guard let base = URL(string: "https://epub.invalid/" + opf), !references.isEmpty else { throw AppFailure("EPUB 章节顺序为空") }
        return try references.map { id in
            guard let href = manifest[id], let url = URL(string: href, relativeTo: base)?.absoluteURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw AppFailure("EPUB 章节引用无效") }
            return String(components.percentEncodedPath.dropFirst())
        }
    }
}
