import Foundation
import ReadiumShared

/// Maps KOReader chapter numbers to Readium resources. The DOM bridge owns the path inside each resource.
@MainActor final class EPUBReadingPosition {
    struct Target {
        let resource: Link
        let path: String
    }

    private static let chapterPrefix = #/^\/body\/DocFragment(?:\[([0-9]+)\])?\/body(?=\/|\.|$)/#
    private let spine: [String]
    private let spineIndices: [String: Int]
    private let resources: [String: Link]
    private let progressionRanges: [String: ClosedRange<Double>]

    init(publication: Publication, spine: [String]) async {
        let order = publication.readingOrder
        self.spine = spine.isEmpty ? order.map(\.href) : spine
        spineIndices = Dictionary(self.spine.enumerated().map { (EPUBPositionBridge.normalize($0.element), $0.offset) },
            uniquingKeysWith: { first, _ in first })
        resources = Dictionary(order.map { (EPUBPositionBridge.normalize($0.href), $0) }, uniquingKeysWith: { first, _ in first })
        let positions = (try? await publication.positionsByReadingOrder().get()) ?? []
        let starts = order.indices.map { index in
            positions.indices.contains(index)
                ? (positions[index].first?.locations.totalProgression ?? Double(index) / Double(order.count))
                : Double(index) / Double(order.count)
        }
        var ranges: [String: ClosedRange<Double>] = [:]
        for index in order.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : 1
            ranges[EPUBPositionBridge.normalize(order[index].href)] = starts[index]...max(starts[index], end)
        }
        progressionRanges = ranges
    }

    func resource(matching href: String) -> Link? { resources[EPUBPositionBridge.normalize(href)] }

    func target(for pointer: String) throws -> Target {
        guard let match = pointer.prefixMatch(of: Self.chapterPrefix) else { throw AppFailure("Unsupported KOReader position format.") }
        let chapter: Int
        if let value = match.output.1 {
            guard let number = Int(value), number > 0 else { throw AppFailure("Invalid chapter number.") }
            chapter = number - 1
        } else {
            chapter = 0
        }
        guard spine.indices.contains(chapter) else { throw AppFailure("The remote chapter is missing from this book. Check that both devices have the same edition.") }
        guard let resource = resource(matching: spine[chapter]) else {
            throw AppFailure("The remote position refers to a non-linear or unsupported chapter.")
        }
        return Target(resource: resource, path: String(pointer[match.range.upperBound...]))
    }

    func pointer(path: String, href: String) -> String? {
        guard let index = spineIndices[EPUBPositionBridge.normalize(href)] else { return nil }
        let fragment = spine.count == 1 ? "DocFragment" : "DocFragment[\(index + 1)]"
        return "/body/\(fragment)/body\(path)"
    }

    static func chapterStart(_ resource: Link?) throws -> Locator {
        guard let resource, let href = AnyURL(string: resource.href) else { throw AppFailure("Couldn’t open the chapter.") }
        return Locator(href: href, mediaType: resource.mediaType ?? .xhtml, locations: .init(progression: 0))
    }

    static func locator(for link: Link) throws -> Locator {
        let fragments = link.href.components(separatedBy: "#")
        return try chapterStart(link).copy(locations: {
            if fragments.count > 1 { $0.fragments = [fragments.dropFirst().joined(separator: "#")] }
        })
    }

    static func continuousDestination(_ value: Any, from locator: Locator) throws -> (locator: Locator, offset: Double) {
        guard let result = value as? [String: Any], let offset = result["verticalOffset"] as? Double, offset.isFinite else {
            throw AppFailure("Couldn’t resolve the remote reading position.")
        }
        return (try EPUBDOMAnchor(result).continuousLocator(from: locator), offset)
    }

    static func continuousOffsetScript(for locator: Locator) throws -> String {
        let locations = locator.locations.otherLocations
        let fragment = locator.locations.fragments.first ?? locator.href.string.components(separatedBy: "#").dropFirst().joined(separator: "#")
        var target: [String: Any] = ["selector": locations["cssSelector"] ?? "", "fragment": fragment,
            "highlight": locator.text.highlight ?? "", "progression": locator.locations.progression ?? 0]
        target["textNodeIndex"] = locations["continuousTextNodeIndex"]
        target["textOffset"] = locations["continuousTextOffset"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: target), as: UTF8.self)
        return "window.SimpleReaderContinuousOffset(\(json))"
    }

    func adjusted(_ locator: Locator) -> Locator {
        guard let progression = locator.locations.progression,
              let range = progressionRanges[EPUBPositionBridge.normalize(locator.href.string)] else { return locator }
        let total = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(progression, 0), 1)
        return locator.copy(locations: { $0.totalProgression = total })
    }

    func capture(_ locator: Locator, in navigator: EPUBReadingNavigator) async throws -> String {
        guard let resource = resource(matching: locator.href.string) else { throw AppFailure("The current chapter is missing from the EPUB reading order.") }
        let value = try await navigator.evaluatePositionJavaScript("SimpleReaderBridge.capture();", in: resource.href)
        guard let path = value as? String, let pointer = pointer(path: path, href: resource.href) else {
            throw AppFailure("Couldn’t get the EPUB reading position.")
        }
        return pointer
    }

    func contentsID(at locator: Locator?, in navigator: EPUBReadingNavigator, contents: [ContentsItem]) async -> UUID? {
        guard let locator, let resource = resource(matching: locator.href.string) else { return nil }
        let href = EPUBPositionBridge.normalize(resource.href)
        let candidates = contents.filter { item in
            item.link.map { EPUBPositionBridge.normalize($0.href) == href } ?? false
        }
        let order = navigator.publication.readingOrder.map { EPUBPositionBridge.normalize($0.href) }
        let preceding = order.firstIndex(of: href).flatMap { resourceIndex in
            contents.last { item in
                guard let link = item.link,
                      let index = order.firstIndex(of: EPUBPositionBridge.normalize(link.href)) else { return false }
                return index < resourceIndex
            }
        }
        let fallback = candidates.first?.id ?? preceding?.id
        guard !candidates.isEmpty else { return fallback }
        do {
            let fragments = candidates.map { $0.link?.href.components(separatedBy: "#").dropFirst().joined(separator: "#") ?? "" }
            let json = String(decoding: try JSONEncoder().encode(fragments), as: UTF8.self)
            let result = try await navigator.evaluatePositionJavaScript(
                "SimpleReaderBridge.contentsIndex(\(json));", in: resource.href)
            guard let index = result as? Int else { return fallback }
            if candidates.indices.contains(index) { return candidates[index].id }
            return index == -1 ? preceding?.id : fallback
        } catch {
            return fallback
        }
    }
}

private enum EPUBDOMAnchor {
    case element(selector: String)
    case text(selector: String, nodeIndex: Int, utf16Offset: Int, quote: Locator.Text)

    init(_ result: [String: Any]) throws {
        let failure = AppFailure("Couldn’t resolve the remote reading position.")
        guard let selector = result["cssSelector"] as? String else { throw failure }
        switch result["kind"] as? String {
        case "element":
            self = .element(selector: selector)
        case "text":
            guard let index = result["textNodeIndex"] as? Int, let offset = result["textOffset"] as? Int,
                  index >= 0, offset >= 0 else { throw failure }
            self = .text(selector: selector, nodeIndex: index, utf16Offset: offset,
                quote: .init(after: result["after"] as? String, before: result["before"] as? String, highlight: result["highlight"] as? String))
        default:
            throw failure
        }
    }

    func continuousLocator(from start: Locator) -> Locator {
        switch self {
        case .element(let selector):
            return start.copy(locations: { $0.otherLocations["cssSelector"] = selector })
        case .text(let selector, let index, let offset, let quote):
            return start.copy(locations: {
                $0.otherLocations["cssSelector"] = selector
                $0.otherLocations["continuousTextNodeIndex"] = index
                $0.otherLocations["continuousTextOffset"] = offset
            }, text: { $0 = quote })
        }
    }
}
