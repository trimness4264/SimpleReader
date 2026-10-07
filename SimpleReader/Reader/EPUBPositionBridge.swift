import Foundation
import ReadiumShared
import ReadiumNavigator

@MainActor enum EPUBPositionBridge {
    static var source: String { get throws {
        guard let url = Bundle.main.url(forResource: "EPUBPositionBridge", withExtension: "js") else { throw AppFailure("缺少 EPUB 定位脚本") }
        return try String(contentsOf: url, encoding: .utf8)
    } }
    static func normalize(_ href: String) -> String { (href.components(separatedBy: "#")[0].removingPercentEncoding ?? href).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static func quoted(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [text])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
    static func spineIndex(_ pointer: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: "^/body/DocFragment(?:\\[(\\d+)\\])?/body(?:/|$)")
        let range = NSRange(pointer.startIndex..., in: pointer)
        guard let match = regex.firstMatch(in: pointer, range: range) else { throw AppFailure("不支持的 KOReader 定位格式") }
        if let value = Range(match.range(at: 1), in: pointer), let n = Int(pointer[value]), n > 0 { return n - 1 }
        if match.range(at: 1).location == NSNotFound { return 0 }
        throw AppFailure("无效的章节编号")
    }
    static func capture(navigator: EPUBNavigatorViewController, locator: Locator, spine: [String]? = nil) async throws -> String {
        let href = normalize(locator.href.string)
        let hrefs = spine ?? navigator.publication.readingOrder.map(\.href)
        guard let index = hrefs.firstIndex(where: { normalize($0) == href }) else { throw AppFailure("当前章节不在 EPUB 阅读顺序中") }
        let value = try await navigator.evaluateJavaScript("\(try source)\nwindow.SimpleReaderBridge.capture(\(index), \(hrefs.count == 1 ? "true" : "false"));").get()
        guard let pointer = value as? String else { throw AppFailure("无法获取 EPUB 阅读位置") }
        return pointer
    }
    static func locator(pointer: String, navigator: EPUBNavigatorViewController, spine: [String]? = nil) async throws -> Locator {
        let index = try spineIndex(pointer)
        let hrefs = spine ?? navigator.publication.readingOrder.map(\.href)
        guard hrefs.indices.contains(index) else { throw AppFailure("远端章节不在本书中，请检查两端图书版本") }
        guard let link = navigator.publication.readingOrder.first(where: { normalize($0.href) == normalize(hrefs[index]) }) else { throw AppFailure("远端位置属于非线性或不支持的章节") }
        guard await navigator.go(to: link) else { throw AppFailure("无法打开远端章节") }
        var lastError: Error = AppFailure("EPUB 章节尚未加载")
        for _ in 0..<20 {
            try Task.checkCancellation()
            do {
                guard navigator.currentLocation?.href.string.components(separatedBy: "#")[0] == link.href.components(separatedBy: "#")[0] else { throw AppFailure("正在切换章节") }
                let value = try await navigator.evaluateJavaScript("\(try source)\nwindow.SimpleReaderBridge.resolve(\(try quoted(pointer)));").get()
                guard let result = value as? [String: Any], let selector = result["cssSelector"] as? String else { throw AppFailure("无法解析远端正文位置") }
                var json: [String: Any] = ["href": link.href, "type": link.mediaType?.string ?? "application/xhtml+xml", "locations": ["cssSelector": selector]]
                if let highlight = result["highlight"] as? String, !highlight.isEmpty {
                    json["text"] = ["highlight": highlight, "before": result["before"] as? String ?? "", "after": result["after"] as? String ?? ""]
                } else {
                    // Readium 3.8 dispatches selector navigation only when highlight
                    // is non-nil. An empty quote takes its JS element-selector path,
                    // allowing images/SVG/body to navigate without fabricated text.
                    json["text"] = ["highlight": ""]
                }
                guard let locator = try Locator(json: json) else { throw AppFailure("无法生成 Readium 定位") }
                return locator
            } catch { lastError = error; try await Task.sleep(nanoseconds: 100_000_000) }
        }
        throw lastError
    }
}
