import Foundation
import ReadiumShared
import ReadiumNavigator
import WebKit

/// Owns the publication's chapter mapping and the DOM work needed to capture or move a position.
@MainActor final class EPUBReadingPosition {
    private let publication: Publication
    let spine: [String]
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

    func initialPosition(in navigator: EPUBReadingNavigator, updatedAt: Date, isCurrent: @MainActor () -> Bool = { true }) async throws -> ReadingPosition? {
        // A cold WebKit chapter can take longer than the normal navigation timeout.
        for _ in 0..<100 {
            try check(isCurrent)
            if let location = navigator.currentLocation {
                let locator = adjusted(location)
                do {
                    let pointer = try await capture(locator, in: navigator)
                    try check(isCurrent)
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

    func go(to locator: Locator, in navigator: EPUBReadingNavigator, isCurrent: @MainActor () -> Bool) async throws {
        try check(isCurrent)
        let moved = await navigator.go(to: locator)
        try check(isCurrent)
        guard moved else { throw AppFailure("Couldn’t jump to the selected position.") }
    }

    func go(to link: Link, in navigator: EPUBReadingNavigator, isCurrent: @MainActor () -> Bool) async throws {
        try check(isCurrent)
        let moved = await navigator.go(to: link)
        try check(isCurrent)
        guard moved else { throw AppFailure("Couldn’t open the chapter.") }
    }

    func go(toProgression value: Double, in navigator: EPUBReadingNavigator, isCurrent: @MainActor () -> Bool) async throws -> Locator {
        guard let locator = await publication.locate(progression: value) else { throw AppFailure("Couldn’t locate the position by percentage.") }
        try await go(to: locator, in: navigator, isCurrent: isCurrent)
        return adjusted(locator)
    }

    func go(toPointer pointer: String, in navigator: EPUBReadingNavigator, isCurrent: @MainActor () -> Bool) async throws -> Locator {
        try check(isCurrent)
        let locator = try await EPUBPositionBridge.locator(pointer: pointer, navigator: navigator,
            spine: spine, isCurrent: isCurrent)
        try await go(to: locator, in: navigator, isCurrent: isCurrent)
        return adjusted(locator)
    }

    func restore(_ locator: Locator?, pointer: String?, in navigator: EPUBReadingNavigator, isCurrent: @MainActor () -> Bool) async throws {
        if let locator = locator {
            // Continuous navigation confirms its target document and layout before returning.
            try await go(to: locator, in: navigator, isCurrent: isCurrent)
        }
        if let pointer = pointer {
            _ = try await go(toPointer: pointer, in: navigator, isCurrent: isCurrent)
        } else if locator == nil {
            throw AppFailure("Couldn’t read the last reading position.")
        }
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

    private func check(_ isCurrent: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
}

/// Confirms the Readium viewport and the document it actually evaluates are on the same page.
@MainActor final class PaginatedEPUBPosition {
    struct Page {
        let locator: Locator
        let pointer: String?
    }

    private let navigator: EPUBNavigatorViewController
    private let positions: EPUBReadingPosition
    private let spineIndices: [String: Int]
    private let isFixedLayout: Bool
    private let initialLocator: Locator?
    private var lastConfirmedLocation: Locator?
    private var isMoving = false
    private var abandonedMove = false

    var needsReplacement: Bool { isMoving || abandonedMove }

    var fixedSpreadLocation: Locator? {
        guard isFixedLayout, let lastConfirmedLocation,
              navigator.viewport?.readingOrder.contains(where: { matches($0.string, lastConfirmedLocation.href.string) }) == true else { return nil }
        return lastConfirmedLocation
    }

    init(navigator: EPUBNavigatorViewController, positions: EPUBReadingPosition, initialLocator: Locator?) {
        self.navigator = navigator
        self.positions = positions
        self.initialLocator = initialLocator
        isFixedLayout = navigator.publication.metadata.layout == .fixed
        let indices = Dictionary(positions.spine.enumerated().map { index, href in (EPUBPositionBridge.normalize(href), index) },
            uniquingKeysWith: { first, _ in first })
        spineIndices = Dictionary(navigator.publication.readingOrder.compactMap { link in
            indices[EPUBPositionBridge.normalize(link.href)].map { (link.href, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    func open(pointer: String?, isCurrent: @escaping @MainActor () -> Bool) async throws -> Page {
        let deadline = ContinuousClock.now + .seconds(10)
        let locator = try initialLocator.map(navigator.publication.normalizeLocator) ?? chapterStart(navigator.publication.readingOrder.first)
        if let pointer {
            // Readium may still be initializing, with a saved locator but no loaded spread.
            _ = try await confirm(nil, deadline: deadline, isCurrent: isCurrent)
            do {
                return try await move(to: locator, pointer: pointer, isCurrent: isCurrent)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Older installations may have saved an XPointer that no longer resolves.
                guard initialLocator != nil else { throw error }
                return try await move(to: locator, isCurrent: isCurrent)
            }
        }
        if initialLocator?.text.highlight != nil {
            _ = try await confirm(nil, deadline: deadline, isCurrent: isCurrent)
            return try await move(to: locator, isCurrent: isCurrent)
        }
        return try await confirm(locator, deadline: deadline, isCurrent: isCurrent)
    }

    func move(to locator: Locator?, pointer: String? = nil, isCurrent: @escaping @MainActor () -> Bool) async throws -> Page {
        try check(isCurrent)
        let deadline = ContinuousClock.now + .seconds(5)
        let target: Locator
        let request: Locator
        if let pointer {
            target = try chapterStart(EPUBPositionBridge.link(for: pointer, in: navigator.publication, spine: positions.spine))
            // Start near the saved page when it belongs to the XPointer's resource.
            let progression = locator.flatMap { matches($0.href.string, target.href.string) ? $0.locations.progression : nil }
            request = target.copy(locations: { $0.progression = progression ?? 0 })
        } else if let locator {
            target = navigator.publication.normalizeLocator(locator)
            request = target.copy(text: { $0 = Locator.Text() })
        } else {
            throw AppFailure("Couldn’t read the last reading position.")
        }
        if navigator.viewport == nil {
            _ = try await confirm(nil, deadline: deadline, isCurrent: isCurrent)
        }
        try await go(to: request, deadline: deadline, isCurrent: isCurrent)
        return try await confirm(target, pointer: pointer, deadline: deadline, isCurrent: isCurrent)
    }

    func visiblePage(matching expected: Locator? = nil, after origin: Locator? = nil,
                     isCurrent: @escaping @MainActor () -> Bool) async throws -> Page {
        try await confirm(expected, matchPosition: false, after: origin, deadline: ContinuousClock.now + .seconds(5),
            isCurrent: isCurrent)
    }

    func turn(forward: Bool, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        let navigator = navigator
        let options = NavigatorGoOptions(animated: false)
        return try await bounded(until: ContinuousClock.now + .seconds(5), movingPage: true, isCurrent: isCurrent) {
            forward ? await navigator.goForward(options: options) : await navigator.goBackward(options: options)
        }
    }

    private struct Sample: Equatable {
        let href: String
        let layout: String
        let pointer: String?
        let webView: ObjectIdentifier
    }

    private func confirm(_ target: Locator?, pointer: String? = nil, matchPosition: Bool = true, after origin: Locator? = nil,
                         deadline: ContinuousClock.Instant, isCurrent: @escaping @MainActor () -> Bool) async throws -> Page {
        let source = try EPUBPositionBridge.source
        var request: [String: Any] = ["progression": target?.locations.progression ?? 0]
        request["fragment"] = target?.locations.fragments.first
        request["pointer"] = pointer
        let targetJSON = target == nil || !matchPosition ? "null" : String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let indicesJSON = String(decoding: try JSONSerialization.data(withJSONObject: spineIndices), as: UTF8.self)
        let expected = target.flatMap { resource(matching: $0.href.string)?.href }
        if target != nil, expected == nil { throw AppFailure("Couldn’t open the chapter.") }
        var previous: Sample?
        while ContinuousClock.now < deadline {
            try check(isCurrent)
            var observed: Sample?
            let href = expected ?? (isFixedLayout ? navigator.viewport?.readingOrder.first?.string : nil)
            if let webView = presentedWebView(), !isFixedLayout || href != nil {
                let script = try presentationScript(source: source, href: href, target: targetJSON, indices: indicesJSON)
                let result = try await bounded(until: deadline, isCurrent: isCurrent) {
                    (try? await webView.evaluateJavaScript(script)) as? [String: Any]
                }
                if presentedWebView() === webView, let result, let href = result["href"] as? String,
                   let resource = resource(matching: href), expected == nil || expected == resource.href {
                    if result["missingAnchor"] as? Bool == true {
                        throw AppFailure("Couldn’t jump to the selected position.")
                    }
                    if let progression = result["anchorProgression"] as? Double {
                        let locator = try chapterStart(resource).copy(locations: { $0.progression = progression })
                        try await go(to: locator, deadline: deadline, isCurrent: isCurrent)
                    }
                    if let layout = result["layout"] as? String,
                       let progression = result["progression"] as? Double, let tolerance = result["tolerance"] as? Double,
                       let locator = confirmedLocator(for: resource, progression: progression, tolerance: tolerance),
                       origin.map({ !matches($0.href.string, resource.href) || abs(($0.locations.progression ?? 0) - progression) > tolerance }) ?? true {
                        let pointer = result["pointer"] as? String
                        let sample = Sample(href: resource.href, layout: layout, pointer: pointer, webView: ObjectIdentifier(webView))
                        if previous == sample {
                            let location = positions.adjusted(locator)
                            lastConfirmedLocation = location
                            return Page(locator: location, pointer: pointer)
                        }
                        observed = sample
                    }
                }
            }
            previous = observed
            try await Task.sleep(for: .milliseconds(25))
        }
        try check(isCurrent)
        throw AppFailure("Restoring the text timed out. Try again.")
    }

    private func resource(matching href: String?) -> Link? {
        guard let href else { return nil }
        return navigator.publication.readingOrder.first { matches($0.href, href) }
    }

    private func presentationScript(source: String, href: String?, target: String, indices: String) throws -> String {
        let resource = try href.map(EPUBPositionBridge.quoted) ?? "null"
        let probe = "\(source)\nwindow.SimpleReaderBridge.presentation(\(resource), \(target), \(indices), \(positions.spine.count == 1));"
        // A fixed-layout spread wraps its resources in separate frames.
        return isFixedLayout ? "window.spread?.eval(\(resource), \(try EPUBPositionBridge.quoted(probe)))" : probe
    }

    private func presentedWebView() -> WKWebView? {
        guard let view = navigator.viewIfLoaded, view.window != nil else { return nil }
        return ReadiumPageTurnSurface.presentedWebView(in: view, viewport: view)
    }

    private func confirmedLocator(for resource: Link, progression: Double, tolerance: Double) -> Locator? {
        if let locator = navigator.currentLocation, matches(locator.href.string, resource.href),
           abs((locator.locations.progression ?? 0) - progression) <= tolerance {
            return locator
        }
        // Readium publishes scroll changes asynchronously and reports only the leading leaf of a fixed spread.
        return try? chapterStart(resource).copy(locations: { $0.progression = progression })
    }

    private func matches(_ left: String, _ right: String) -> Bool {
        EPUBPositionBridge.normalize(left) == EPUBPositionBridge.normalize(right)
    }

    private func chapterStart(_ resource: Link?) throws -> Locator {
        guard let resource, let href = AnyURL(string: resource.href) else { throw AppFailure("Couldn’t open the chapter.") }
        return Locator(href: href, mediaType: resource.mediaType ?? .xhtml, locations: .init(progression: 0))
    }

    private func go(to locator: Locator, deadline: ContinuousClock.Instant, isCurrent: @escaping @MainActor () -> Bool) async throws {
        let navigator = navigator
        let moved = try await bounded(until: deadline, movingPage: true, isCurrent: isCurrent) { await navigator.go(to: locator) }
        guard moved else { throw AppFailure("Couldn’t jump to the selected position.") }
    }

    private func bounded<Value>(until deadline: ContinuousClock.Instant, movingPage: Bool = false, isCurrent: @escaping @MainActor () -> Bool,
                                operation: @escaping @MainActor () async -> Value) async throws -> Value {
        try check(isCurrent)
        if movingPage {
            guard !needsReplacement else { throw AppFailure("Restoring the text timed out. Try again.") }
            isMoving = true
        }
        // A Readium spread can wait indefinitely for a WebKit load callback.
        var result: Value?
        var started = false
        var validateStart: (@MainActor () -> Bool)? = isCurrent
        let task = Task { @MainActor in
            guard !Task.isCancelled, validateStart?() == true else { return }
            validateStart = nil
            started = true
            result = await operation()
        }
        defer {
            validateStart = nil
            task.cancel()
            if movingPage {
                isMoving = false
                // Readium can finish a cancelled Swift task's move later on the old renderer.
                abandonedMove = started && result == nil
            }
        }
        while ContinuousClock.now < deadline {
            try check(isCurrent)
            if let result { return result }
            try await Task.sleep(for: .milliseconds(16))
        }
        try check(isCurrent)
        throw AppFailure("Restoring the text timed out. Try again.")
    }

    private func check(_ isCurrent: @MainActor () -> Bool) throws {
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
        guard let selector = result["cssSelector"] as? String else { throw AppFailure("Couldn’t resolve the remote reading position.") }
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
        guard let locator = try Locator(json: json) else { throw AppFailure("Couldn’t create a Readium locator.") }
        return locator
    }
}
