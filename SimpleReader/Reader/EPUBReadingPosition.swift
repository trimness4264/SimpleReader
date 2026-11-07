import Foundation
import ReadiumShared
import ReadiumNavigator

/// Owns the publication's chapter mapping and the DOM work needed to capture or move a position.
@MainActor final class EPUBReadingPosition {
    private let publication: Publication
    private let spine: [String]
    private var progressionRanges: [String: ClosedRange<Double>] = [:]

    init(publication: Publication, spine: [String]) async {
        self.publication = publication
        self.spine = spine.isEmpty ? publication.readingOrder.map(\.href) : spine
        let positions = (try? await publication.positionsByReadingOrder().get()) ?? []
        let order = publication.readingOrder
        let starts = order.indices.map { index in
            positions.indices.contains(index)
                ? (positions[index].first?.locations.totalProgression ?? Double(index) / Double(order.count))
                : Double(index) / Double(order.count)
        }
        for index in order.indices {
            let end = index + 1 < starts.count ? starts[index + 1] : 1
            progressionRanges[EPUBPositionBridge.normalize(order[index].href)] = starts[index]...max(starts[index], end)
        }
    }

    func adjusted(_ locator: Locator) -> Locator {
        guard let progression = locator.locations.progression,
              let range = progressionRanges[EPUBPositionBridge.normalize(locator.href.string)] else { return locator }
        let total = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(progression, 0), 1)
        return locator.copy(locations: { $0.totalProgression = total })
    }

    func capture(_ locator: Locator, in navigator: EPUBReadingNavigator) async throws -> String {
        try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: spine)
    }

    func initialPosition(in navigator: EPUBReadingNavigator, updatedAt: Date) async throws -> ReadingPosition? {
        // A cold WebKit chapter can take longer than the normal navigation timeout.
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let location = navigator.currentLocation {
                let locator = adjusted(location)
                do {
                    let pointer = try await capture(locator, in: navigator)
                    return ReadingPosition(progression: locator.locations.totalProgression ?? 0,
                        locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: updatedAt)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Retry text, media, and empty chapter anchors until the document is ready.
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    func go(to locator: Locator, in navigator: EPUBReadingNavigator, isCurrent: () -> Bool) async throws {
        try check(isCurrent)
        guard await navigator.go(to: locator) else { throw AppFailure("无法跳转到指定位置") }
        try await settle(isCurrent)
    }

    func go(to link: Link, in navigator: EPUBReadingNavigator, isCurrent: () -> Bool) async throws {
        try check(isCurrent)
        guard await navigator.go(to: link) else { throw AppFailure("无法打开章节") }
        try await settle(isCurrent)
    }

    func go(toProgression value: Double, in navigator: EPUBReadingNavigator, isCurrent: () -> Bool) async throws -> Locator {
        guard let locator = await publication.locate(progression: value) else { throw AppFailure("无法按百分比定位") }
        try await go(to: locator, in: navigator, isCurrent: isCurrent)
        return adjusted(locator)
    }

    func go(toPointer pointer: String, in navigator: EPUBReadingNavigator, isCurrent: () -> Bool) async throws -> Locator {
        try check(isCurrent)
        let locator = try await EPUBPositionBridge.locator(pointer: pointer, navigator: navigator,
            spine: spine, isCurrent: isCurrent)
        try await go(to: locator, in: navigator, isCurrent: isCurrent)
        return adjusted(locator)
    }

    func restore(_ locator: Locator?, pointer: String?, in navigator: EPUBReadingNavigator, isCurrent: () -> Bool) async throws {
        if let locator = locator {
            var loaded = false
            for _ in 0..<50 {
                try check(isCurrent)
                if await navigator.go(to: locator) {
                    try check(isCurrent)
                    let result = await navigator.evaluateJavaScript("Boolean(document.body && document.readyState !== 'loading')")
                    try check(isCurrent)
                    if (try? result.get()) as? Bool == true { loaded = true; break }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard loaded else { throw AppFailure("正文恢复超时，请重试") }
        }
        if let pointer = pointer {
            _ = try await go(toPointer: pointer, in: navigator, isCurrent: isCurrent)
        } else {
            guard locator != nil else { throw AppFailure("无法读取上次阅读位置") }
            try await settle(isCurrent)
        }
    }

    func settledPage(in navigator: EPUBNavigatorViewController) async throws -> (locator: Locator, pointer: String) {
        guard let visible = await navigator.firstVisibleElementLocator() else { throw AppFailure("无法读取翻页后的位置，请重试。") }
        let result = try await navigator.evaluateJavaScript("Math.abs(window.scrollX) / document.scrollingElement.scrollWidth").get()
        guard let fraction = result as? Double else { throw AppFailure("无法读取翻页后的进度") }
        let locator = adjusted(visible.copy(locations: { $0.progression = min(max(fraction, 0), 1) }))
        return (locator, try await capture(locator, in: navigator))
    }

    func contentsID(in navigator: EPUBReadingNavigator, contents: [ContentsItem]) async -> UUID? {
        guard let locator = navigator.currentLocation else { return nil }
        let href = EPUBPositionBridge.normalize(locator.href.string)
        let candidates = contents.filter { item in
            item.link.map { EPUBPositionBridge.normalize($0.href) == href } ?? false
        }
        let order = publication.readingOrder.map { EPUBPositionBridge.normalize($0.href) }
        let preceding: ContentsItem?
        if let resourceIndex = order.firstIndex(of: href) {
            preceding = contents.last { item in
                guard let link = item.link,
                      let index = order.firstIndex(of: EPUBPositionBridge.normalize(link.href)) else { return false }
                return index < resourceIndex
            }
        } else {
            preceding = nil
        }
        let fallback = candidates.first?.id ?? preceding?.id
        guard !candidates.isEmpty else { return fallback }
        do {
            let pointer = try await capture(locator, in: navigator)
            let fragments = candidates.map { $0.link?.href.components(separatedBy: "#").dropFirst().joined(separator: "#") ?? "" }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: fragments), as: UTF8.self)
            let result = try await navigator.evaluateJavaScript("""
                (() => {
                    const location = SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(pointer)));
                    const element = document.querySelector(location.cssSelector);
                    if (!element) return -1;
                    const node = element.childNodes[location.textNodeIndex] || element;
                    const fragments = \(json);
                    let current = -1;
                    fragments.forEach((fragment, index) => {
                        if (!fragment) { current = index; return; }
                        let id = fragment;
                        try { id = decodeURIComponent(fragment); } catch (_) {}
                        const target = document.getElementById(id);
                        if (target && (target === node || target.contains(node) ||
                            (target.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING))) current = index;
                    });
                    return current;
                })()
                """).get()
            guard let index = result as? Int else { return fallback }
            if candidates.indices.contains(index) { return candidates[index].id }
            return index == -1 ? preceding?.id : fallback
        } catch {
            return fallback
        }
    }

    private func settle(_ isCurrent: () -> Bool) async throws {
        try check(isCurrent)
        // Keep Readium's delayed location events out of user-movement persistence.
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(isCurrent)
    }

    private func check(_ isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
}

/// The DOM anchor is shared; each navigator owns the locator fields it understands.
struct EPUBTextAnchor {
    let selector: String
    let textNodeIndex: Int?
    let textOffset: Int?
    let highlight: String
    let before: String
    let after: String

    init(result: [String: Any]) throws {
        guard let selector = result["cssSelector"] as? String else { throw AppFailure("无法解析远端正文位置") }
        self.selector = selector
        textNodeIndex = result["textNodeIndex"] as? Int
        textOffset = result["textOffset"] as? Int
        highlight = result["highlight"] as? String ?? ""
        before = result["before"] as? String ?? ""
        after = result["after"] as? String ?? ""
    }

    func locator(in link: Link, additionalLocations: [String: Any] = [:]) throws -> Locator {
        var locations = additionalLocations
        locations["cssSelector"] = selector
        // An empty highlight is required for Readium's element-selector navigation.
        let json: [String: Any] = ["href": link.href, "type": link.mediaType?.string ?? "application/xhtml+xml",
            "locations": locations, "text": ["highlight": highlight, "before": before, "after": after]]
        guard let locator = try Locator(json: json) else { throw AppFailure("无法生成 Readium 定位") }
        return locator
    }
}
