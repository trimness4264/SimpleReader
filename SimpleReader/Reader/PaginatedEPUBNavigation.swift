import Foundation
import ReadiumShared
import ReadiumNavigator
import WebKit

/// Confirms the Readium viewport and the document it actually evaluates are on the same page.
@MainActor final class PaginatedEPUBNavigation {
    struct Page {
        let locator: Locator
        let pointer: String?
    }

    private let navigator: EPUBNavigatorViewController
    private let positions: EPUBReadingPosition
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
    }

    func open(pointer: String?, isCurrent: @escaping @MainActor () -> Bool) async throws -> Page {
        let deadline = ContinuousClock.now + .seconds(10)
        let locator = try initialLocator.map(navigator.publication.normalizeLocator) ?? EPUBReadingPosition.chapterStart(navigator.publication.readingOrder.first)
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
        let anchor = try pointer.map(positions.target(for:))
        if let anchor {
            target = try EPUBReadingPosition.chapterStart(anchor.resource)
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
        while true {
            switch try await waitForPresentation(target, path: anchor?.path, deadline: deadline, isCurrent: isCurrent) {
            case .visible(let page):
                return page
            case .offscreenAnchor(let resource, let progression):
                let page = try EPUBReadingPosition.chapterStart(resource).copy(locations: { $0.progression = progression })
                try await go(to: page, deadline: deadline, isCurrent: isCurrent)
            }
        }
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
        let path: String?
        let webView: ObjectIdentifier
    }

    private enum Presentation {
        case visible(Page)
        case offscreenAnchor(Link, progression: Double)
    }

    private func confirm(_ target: Locator?, matchPosition: Bool = true, after origin: Locator? = nil,
                         deadline: ContinuousClock.Instant, isCurrent: @escaping @MainActor () -> Bool) async throws -> Page {
        let presentation = try await waitForPresentation(target, matchPosition: matchPosition, after: origin,
            deadline: deadline, isCurrent: isCurrent)
        guard case .visible(let page) = presentation else { throw AppFailure("Couldn’t jump to the selected position.") }
        return page
    }

    private func waitForPresentation(_ target: Locator?, path: String? = nil, matchPosition: Bool = true, after origin: Locator? = nil,
                                     deadline: ContinuousClock.Instant, isCurrent: @escaping @MainActor () -> Bool) async throws -> Presentation {
        let source = try EPUBPositionBridge.source
        var request: [String: Any] = ["progression": target?.locations.progression ?? 0]
        request["fragment"] = target?.locations.fragments.first
        request["path"] = path
        let targetJSON = target == nil || !matchPosition ? "null" : String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let expected = target.flatMap { positions.resource(matching: $0.href.string)?.href }
        if target != nil, expected == nil { throw AppFailure("Couldn’t open the chapter.") }
        var previous: Sample?
        while ContinuousClock.now < deadline {
            try check(isCurrent)
            var observed: Sample?
            let href = expected ?? (isFixedLayout ? navigator.viewport?.readingOrder.first?.string : nil)
            if let webView = navigator.positionWebView, !isFixedLayout || href != nil {
                let resource = try href.map(EPUBPositionBridge.quoted) ?? "null"
                let script = try navigator.positionScript("\(source)\nSimpleReaderBridge.presentation(\(resource), \(targetJSON));", in: resource)
                let result = try await bounded(until: deadline, isCurrent: isCurrent) {
                    (try? await webView.evaluateJavaScript(script)) as? [String: Any]
                }
                if navigator.positionWebView === webView, let result, let href = result["href"] as? String,
                   let resource = positions.resource(matching: href), expected == nil || expected == resource.href {
                    if result["missingAnchor"] as? Bool == true {
                        throw AppFailure("Couldn’t jump to the selected position.")
                    }
                    if let progression = result["anchorProgression"] as? Double {
                        return .offscreenAnchor(resource, progression: progression)
                    }
                    if let layout = result["layout"] as? String,
                       let progression = result["progression"] as? Double, let tolerance = result["tolerance"] as? Double,
                       let locator = confirmedLocator(for: resource, progression: progression, tolerance: tolerance),
                       origin.map({ !matches($0.href.string, resource.href) || abs(($0.locations.progression ?? 0) - progression) > tolerance }) ?? true {
                        let path = result["path"] as? String
                        let sample = Sample(href: resource.href, layout: layout, path: path, webView: ObjectIdentifier(webView))
                        if previous == sample {
                            let location = positions.adjusted(locator)
                            lastConfirmedLocation = location
                            return .visible(Page(locator: location, pointer: path.flatMap { positions.pointer(path: $0, href: resource.href) }))
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

    private func confirmedLocator(for resource: Link, progression: Double, tolerance: Double) -> Locator? {
        if let locator = navigator.currentLocation, matches(locator.href.string, resource.href),
           abs((locator.locations.progression ?? 0) - progression) <= tolerance {
            return locator
        }
        // Readium publishes scroll changes asynchronously and reports only the leading leaf of a fixed spread.
        return try? EPUBReadingPosition.chapterStart(resource).copy(locations: { $0.progression = progression })
    }

    private func matches(_ left: String, _ right: String) -> Bool {
        EPUBPositionBridge.normalize(left) == EPUBPositionBridge.normalize(right)
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

extension EPUBNavigatorViewController: EPUBReadingNavigator {
    fileprivate var positionWebView: WKWebView? {
        guard let view = viewIfLoaded, view.window != nil else { return nil }
        return ReadiumPageTurnSurface.presentedWebView(in: view, viewport: view)
    }

    fileprivate func positionScript(_ script: String, in resourceJSON: String) throws -> String {
        // A fixed spread wraps its leading and trailing resources in separate frames.
        guard publication.metadata.layout == .fixed else { return script }
        return "window.spread?.eval(\(resourceJSON), \(try EPUBPositionBridge.quoted(script)))"
    }

    func evaluatePositionJavaScript(_ script: String, in href: String) async throws -> Any {
        guard let webView = positionWebView else { throw AppFailure("Couldn’t get the EPUB reading position.") }
        let resource = try EPUBPositionBridge.quoted(href)
        let result = try await webView.evaluateJavaScript(try positionScript("""
            if (window.readium?.link?.href !== \(resource)) throw Error('The chapter is no longer visible');
            \(try EPUBPositionBridge.source)
            \(script)
            """, in: resource))
        guard !Task.isCancelled, positionWebView === webView else { throw CancellationError() }
        guard let result else { throw AppFailure("Couldn’t get the EPUB reading position.") }
        return result
    }
}
