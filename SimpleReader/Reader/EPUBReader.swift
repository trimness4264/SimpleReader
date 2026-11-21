import UIKit
import WebKit
import ReadiumShared
import ReadiumNavigator

@MainActor protocol EPUBReadingNavigator: AnyObject {
    var publication: Publication { get }
    var currentLocation: Locator? { get }
    func evaluatePositionJavaScript(_ script: String, in href: String) async throws -> Any
}

/// One rendering lifetime. Replacing a mode creates a new reader and invalidates the old instance.
@MainActor final class EPUBReader: NSObject, EPUBNavigatorDelegate {
    struct Configuration {
        var settings: ReaderSettings
        var twoPages: Bool
        var systemIsDark: Bool
        var scrollInsets: UIEdgeInsets?
    }

    struct Snapshot {
        let position: ReadingPosition
        let locator: Locator?
    }

    enum Capture {
        case movement(Locator), navigation, settledPage(after: Locator?)
        case origin(Locator, saved: ReadingPosition?)
    }

    enum Target {
        case progression(Double), link(Link), checkpoint(Locator?, pointer: String?)
    }

    enum Event {
        case locationChanged(Locator), movementBegan, linkActivated(Link)
        case tapped(CGPoint, CGRect), toggleControls, error(Error)
    }

    private enum Renderer {
        case paginated(EPUBNavigatorViewController)
        case continuous(ContinuousEPUBController)

        var navigator: EPUBReadingNavigator {
            switch self {
            case .paginated(let navigator): return navigator
            case .continuous(let navigator): return navigator
            }
        }
    }

    let contents: [ContentsItem]
    var onEvent: ((Event) -> Void)?
    private let publication: Publication
    private let positions: EPUBReadingPosition
    private let renderer: Renderer
    private let paginatedPosition: PaginatedEPUBNavigation?
    private var configuration: Configuration
    private var closed = false

    var supportsScrolling: Bool { publication.metadata.layout != .fixed }
    var isScrolling: Bool {
        if case .continuous = renderer { return true }
        return false
    }
    var isUserScrolling: Bool {
        if case .continuous(let navigator) = renderer { return navigator.isScrolling }
        return false
    }
    var currentLocation: Locator? {
        paginatedPosition?.fixedSpreadLocation ?? renderer.navigator.currentLocation.map(positions.adjusted)
    }
    var needsNavigationReplacement: Bool { paginatedPosition?.needsReplacement == true }

    convenience init(publication: Publication, spine: [String], configuration: @MainActor () -> Configuration, locator: Locator?) async throws {
        let positions = await EPUBReadingPosition(publication: publication, spine: spine)
        func flatten(_ links: [Link], depth: Int = 0) -> [ContentsItem] {
            links.flatMap { [ContentsItem(title: String(repeating: "  ", count: depth) + ($0.title ?? String(localized: "Chapter")),
                link: $0, pdfPage: nil)] + flatten($0.children, depth: depth + 1) }
        }
        let contents = flatten(try await publication.tableOfContents().get())
        try Task.checkCancellation()
        try self.init(publication: publication, positions: positions, contents: contents, configuration: configuration(), locator: locator)
    }

    private init(publication: Publication, positions: EPUBReadingPosition, contents: [ContentsItem],
                 configuration: Configuration, locator: Locator?) throws {
        self.publication = publication
        self.positions = positions
        self.contents = contents
        self.configuration = configuration
        if publication.metadata.layout != .fixed && configuration.settings.layout == .scroll {
            renderer = .continuous(ContinuousEPUBController(publication: publication, initialLocation: locator,
                settings: configuration.settings))
            paginatedPosition = nil
        } else {
            let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator,
                config: .init(preferences: Self.preferences(configuration), fontFamilyDeclarations: try ReaderFonts.declarations()))
            renderer = .paginated(navigator)
            paginatedPosition = PaginatedEPUBNavigation(navigator: navigator, positions: positions, initialLocator: locator)
        }
        super.init()
        switch renderer {
        case .paginated(let navigator):
            navigator.delegate = self
        case .continuous(let navigator):
            navigator.onLocationChanged = { [weak self] locator in
                guard let self, !self.closed else { return }
                self.onEvent?(.locationChanged(self.positions.adjusted(locator)))
            }
            navigator.onScrollBegan = { [weak self] in self?.emit(.movementBegan) }
            navigator.onLinkActivated = { [weak self] in self?.emit(.linkActivated($0)) }
            navigator.onError = { [weak self] in self?.emit(.error($0)) }
            navigator.onContentTap = { [weak self] in self?.emit(.toggleControls) }
            if let insets = configuration.scrollInsets { navigator.updateScrollInsets(insets) }
        }
    }

    func install(in container: ReaderContainerController) {
        switch renderer {
        case .paginated(let navigator):
            container.replaceChild(with: navigator,
                pageTurnSurface: ReadiumPageTurnSurface(content: navigator.view, viewport: container.view,
                    isFixedLayout: !supportsScrolling))
        case .continuous(let navigator):
            container.replaceChild(with: navigator)
        }
    }

    func updating(_ configuration: Configuration, at locator: Locator?) throws -> EPUBReader {
        if (supportsScrolling && configuration.settings.layout == .scroll) != isScrolling {
            return try replacing(configuration, at: locator)
        }
        self.configuration = configuration
        switch renderer {
        case .paginated(let navigator): navigator.submitPreferences(Self.preferences(configuration))
        case .continuous(let navigator): navigator.updateSettings(configuration.settings)
        }
        return self
    }

    func replacing(_ configuration: Configuration, at locator: Locator?) throws -> EPUBReader {
        try EPUBReader(publication: publication, positions: positions, contents: contents, configuration: configuration, locator: locator)
    }

    func updatePageLayout(twoPages: Bool) {
        configuration.twoPages = twoPages
        if case .paginated(let navigator) = renderer { navigator.submitPreferences(Self.preferences(configuration)) }
    }

    func updateSystemAppearance(isDark: Bool) {
        guard configuration.settings.theme == .system, configuration.systemIsDark != isDark else { return }
        configuration.systemIsDark = isDark
        // Changing colors alone does not require restoring the reading position.
        if case .paginated(let navigator) = renderer { navigator.submitPreferences(Self.preferences(configuration)) }
    }

    func updateScrollInsets(_ insets: UIEdgeInsets?) {
        configuration.scrollInsets = insets
        if case .continuous(let navigator) = renderer { navigator.updateScrollInsets(insets ?? .zero) }
    }

    func cancelNavigation() {
        if case .continuous(let navigator) = renderer { navigator.cancelNavigation() }
    }

    func close() {
        closed = true
        onEvent = nil
        switch renderer {
        case .paginated(let navigator): navigator.delegate = nil
        case .continuous(let navigator): navigator.close()
        }
    }

    func initialSnapshot(restoring saved: ReadingPosition?, isCurrent: @escaping @MainActor () -> Bool) async throws -> Snapshot? {
        let updatedAt = saved?.updatedAt ?? Date()
        if let paginatedPosition {
            let page = try await paginatedPosition.open(pointer: saved?.xpointer) { !self.closed && isCurrent() }
            try check(isCurrent)
            return snapshot(of: page, updatedAt: updatedAt)
        }
        if case .continuous(let navigator) = renderer, let pointer = saved?.xpointer {
            let locator = try saved?.locatorJSON.flatMap { try Locator(jsonString: $0) }
            do {
                try await restoreContinuous(locator, pointer: pointer, in: navigator, isCurrent: isCurrent)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Some saved XPointer-only positions no longer resolve. Reopen at the chapter start.
                let fallback = try locator ?? EPUBReadingPosition.chapterStart(publication.readingOrder.first)
                try await navigator.move(to: fallback) { !self.closed && isCurrent() }
            }
        }
        // A cold WebKit chapter can take longer than a normal navigation.
        for _ in 0..<100 {
            try check(isCurrent)
            if let locator = currentLocation {
                do {
                    let pointer = try await positions.capture(locator, in: renderer.navigator)
                    try check(isCurrent)
                    return Snapshot(position: ReadingPosition(progression: locator.locations.totalProgression ?? 0,
                        locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: updatedAt), locator: locator)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Retry capture until the initial document and its layout are ready.
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    func capture(_ request: Capture, fallbackProgression: Double, isCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> Snapshot? {
        try check(isCurrent)
        let navigator = renderer.navigator
        let locator: Locator
        let pointer: String?
        var updatedAt: Date?
        switch request {
        case .movement(let location):
            if let paginatedPosition {
                let page = try await paginatedPosition.visiblePage(matching: location) { !self.closed && isCurrent() }
                try check(isCurrent)
                // Ignore a delayed callback for an earlier page in the same chapter.
                guard page.locator.locations.progression == location.locations.progression else { return nil }
                return snapshot(of: page)
            }
            locator = location
            pointer = try? await positions.capture(locator, in: navigator)
        case .navigation:
            guard let location = currentLocation else { return nil }
            locator = location
            do { pointer = try await positions.capture(locator, in: navigator) }
            catch is CancellationError where isScrolling { throw CancellationError() }
            catch { pointer = nil }
        case .settledPage(let origin):
            guard let paginatedPosition else { return nil }
            let page = try await paginatedPosition.visiblePage(after: origin) { !self.closed && isCurrent() }
            try check(isCurrent)
            return snapshot(of: page)
        case .origin(let location, let saved):
            if let paginatedPosition {
                let page = try await paginatedPosition.visiblePage(matching: location) { !self.closed && isCurrent() }
                try check(isCurrent)
                return snapshot(of: page, updatedAt: saved?.updatedAt ?? Date())
            }
            locator = location
            let captured = try? await positions.capture(locator, in: navigator)
            pointer = captured ?? (locator.jsonString == saved?.locatorJSON ? saved?.xpointer : nil)
            updatedAt = saved?.updatedAt
        }
        try check(isCurrent)
        return Snapshot(position: ReadingPosition(progression: locator.locations.totalProgression ?? fallbackProgression,
            locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: updatedAt ?? Date()), locator: locator)
    }

    @discardableResult
    func move(to target: Target, isCurrent: @escaping @MainActor () -> Bool) async throws -> Snapshot? {
        try check(isCurrent)
        let locator: Locator?
        let pointer: String?
        switch target {
        case .progression(let value):
            guard let position = await publication.locate(progression: value) else { throw AppFailure("Couldn’t locate the position by percentage.") }
            locator = position
            pointer = nil
        case .link(let link):
            if paginatedPosition != nil {
                locator = await publication.locate(link)
            } else {
                locator = try EPUBReadingPosition.locator(for: link)
            }
            pointer = nil
        case .checkpoint(let location, let anchor):
            locator = location
            pointer = anchor
        }
        try check(isCurrent)
        guard locator != nil || pointer != nil else { throw AppFailure("Couldn’t jump to the selected position.") }
        if let paginatedPosition {
            let page = try await paginatedPosition.move(to: locator, pointer: pointer) { !self.closed && isCurrent() }
            try check(isCurrent)
            return snapshot(of: page)
        }
        guard case .continuous(let navigator) = renderer else { return nil }
        try await restoreContinuous(locator, pointer: pointer, in: navigator, isCurrent: isCurrent)
        try check(isCurrent)
        return nil
    }

    private func restoreContinuous(_ locator: Locator?, pointer: String?, in navigator: ContinuousEPUBController,
                                   isCurrent: @MainActor () -> Bool) async throws {
        if let pointer {
            try await navigator.move(to: positions.target(for: pointer)) { !self.closed && isCurrent() }
        } else if let locator {
            try await navigator.move(to: locator) { !self.closed && isCurrent() }
        } else {
            throw AppFailure("Couldn’t read the last reading position.")
        }
    }

    func remoteSnapshot(_ remote: RemoteProgress, approximate: Bool, isCurrent: @escaping @MainActor () -> Bool) async throws -> Snapshot {
        try check(isCurrent)
        let target: Target
        if approximate {
            guard let percentage = remote.percentage else { throw AppFailure("Couldn’t locate the position by percentage.") }
            target = .progression(percentage)
        } else {
            guard let pointer = remote.progress else { throw AppFailure("No remote reading position is available.") }
            target = .checkpoint(nil, pointer: pointer)
        }
        let captured = try await move(to: target, isCurrent: isCurrent)
        try check(isCurrent)
        guard let visible = captured?.locator ?? currentLocation else { throw AppFailure("Couldn’t read the last reading position.") }
        return Snapshot(position: ReadingPosition(progression: remote.percentage ?? visible.locations.totalProgression ?? 0,
            locatorJSON: visible.jsonString, xpointer: approximate ? nil : remote.progress, updatedAt: Date()), locator: visible)
    }

    private func snapshot(of page: PaginatedEPUBNavigation.Page, updatedAt: Date = Date()) -> Snapshot {
        Snapshot(position: ReadingPosition(progression: page.locator.locations.totalProgression ?? 0,
            locatorJSON: page.locator.jsonString, xpointer: page.pointer, updatedAt: updatedAt), locator: page.locator)
    }

    func contentsID() async -> UUID? {
        await positions.contentsID(at: currentLocation, in: renderer.navigator, contents: contents)
    }

    func canBeginPageTurn(isGesture: Bool) -> Bool {
        guard !closed, case .paginated(let navigator) = renderer else { return false }
        return !isGesture || (!navigator.settings.scroll && navigator.currentSelection == nil)
    }

    func towardLeft(forward: Bool) -> Bool {
        guard case .paginated(let navigator) = renderer else { return forward }
        return forward == (navigator.presentation.readingProgression == .ltr)
    }

    func movePage(towardLeft: Bool, isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        try check(isCurrent)
        guard case .paginated(let navigator) = renderer, let paginatedPosition else { return false }
        let forward = towardLeft == (navigator.presentation.readingProgression == .ltr)
        return try await paginatedPosition.turn(forward: forward) { !self.closed && isCurrent() }
    }

    private func check(_ isCurrent: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard !closed, isCurrent() else { throw CancellationError() }
    }

    private static func preferences(_ configuration: Configuration) -> EPUBPreferences {
        let settings = configuration.settings
        let dark = settings.theme.isDark ?? configuration.systemIsDark
        return EPUBPreferences(columnCount: configuration.twoPages ? .two : .one,
            fontFamily: FontFamily(rawValue: settings.font.familyName), fontSize: settings.fontSize / 100,
            lineHeight: settings.lineHeight, pageMargins: settings.pageMargins,
            publisherStyles: false, scroll: false, spread: configuration.twoPages ? .always : .never, theme: dark ? .dark : .light)
    }

    private func emit(_ event: Event) { if !closed { onEvent?(event) } }

    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
        EPUBPositionBridge.installMediaLayout(in: controller)
    }

    func navigator(_ navigator: VisualNavigator, shouldNavigateToLink link: Link) -> Bool {
        guard case .paginated(let active) = renderer, (navigator as AnyObject) === active else { return false }
        emit(.linkActivated(link))
        return false
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard case .paginated(let active) = renderer, (navigator as AnyObject) === active, active.currentSelection == nil else { return }
        emit(.tapped(point, active.view.bounds))
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { emit(.error(error)) }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard case .paginated(let active) = renderer, (navigator as AnyObject) === active else { return }
        if paginatedPosition?.fixedSpreadLocation != nil { return }
        emit(.locationChanged(positions.adjusted(locator)))
    }
}

private enum ReaderFonts {
    static let latin = FontFamily(rawValue: ReaderFont.serif.familyName)
    static let cjk: FontFamily = "LXGW WenKai"

    static func declarations() throws -> [AnyHTMLFontFamilyDeclaration] {
        func face(_ name: String, style: CSSFontStyle = .normal, weight: CSSStandardFontWeight = .normal) throws -> CSSFontFace {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                  let file = FileURL(url: url) else {
                throw AppFailure("Missing reading font: \(name)")
            }
            return CSSFontFace(file: file, style: style, weight: .standard(weight))
        }

        // Latin first: WenKai also contains Latin glyphs, so reversing this stack
        // would prevent mixed-language books from using Source Serif for Western text.
        return [
            CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: ReaderFont.system.familyName),
                alternates: ["PingFang SC", "Hiragino Sans GB", .sansSerif]
            ).eraseToAnyHTMLFontFamilyDeclaration(),
            CSSFontFamilyDeclaration(
                fontFamily: latin,
                alternates: [cjk, .serif],
                fontFaces: [
                    try face("SourceSerif4-Regular"),
                    try face("SourceSerif4-It", style: .italic),
                    try face("SourceSerif4-Bold", weight: .bold),
                    try face("SourceSerif4-BoldIt", style: .italic, weight: .bold)
                ]
            ).eraseToAnyHTMLFontFamilyDeclaration(),
            CSSFontFamilyDeclaration(
                fontFamily: cjk,
                fontFaces: [try face("LXGWWenKai-Regular")]
            ).eraseToAnyHTMLFontFamilyDeclaration()
        ]
    }
}
