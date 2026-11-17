import UIKit
import WebKit
import ReadiumShared
import ReadiumNavigator

@MainActor protocol EPUBReadingNavigator: AnyObject {
    var publication: Publication { get }
    var currentLocation: Locator? { get }
    func evaluateJavaScript(_ script: String) async -> Result<Any, Error>
    func locator(for anchor: EPUBTextAnchor, in link: Link) throws -> Locator
    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool
    func go(to link: Link, options: NavigatorGoOptions) async -> Bool
}

extension EPUBNavigatorViewController: EPUBReadingNavigator {}

extension EPUBReadingNavigator {
    func locator(for anchor: EPUBTextAnchor, in link: Link) throws -> Locator { try anchor.locator(in: link) }
    func go(to locator: Locator) async -> Bool { await go(to: locator, options: .init(animated: false)) }
    func go(to link: Link) async -> Bool { await go(to: link, options: .init(animated: false)) }
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
        case movement(Locator), navigation, settledPage
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
    var currentLocation: Locator? { renderer.navigator.currentLocation.map(positions.adjusted) }

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
        } else {
            renderer = .paginated(try EPUBNavigatorViewController(publication: publication, initialLocation: locator,
                config: .init(preferences: Self.preferences(configuration), fontFamilyDeclarations: try ReaderFonts.declarations())))
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
                pageTurnSurface: ReadiumPageTurnSurface(content: navigator.view, viewport: container.view))
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

    func initialSnapshot(restoring saved: ReadingPosition?, isCurrent: @MainActor () -> Bool) async throws -> Snapshot? {
        let navigator = renderer.navigator
        if let json = saved?.locatorJSON, let locator = try Locator(jsonString: json), let pointer = saved?.xpointer {
            do {
                try await positions.restore(locator, pointer: pointer, in: navigator) { !self.closed && isCurrent() }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await positions.restore(locator, pointer: nil, in: navigator) { !self.closed && isCurrent() }
            }
        }
        let position = try await positions.initialPosition(in: navigator, updatedAt: saved?.updatedAt ?? Date())
        try check(isCurrent)
        return position.map { Snapshot(position: $0, locator: currentLocation) }
    }

    func capture(_ request: Capture, fallbackProgression: Double) async throws -> Snapshot? {
        try check { true }
        let navigator = renderer.navigator
        let locator: Locator
        let pointer: String?
        var updatedAt: Date?
        switch request {
        case .movement(let location):
            locator = location
            pointer = try? await positions.capture(locator, in: navigator)
        case .navigation:
            guard let location = currentLocation else { return nil }
            locator = location
            do { pointer = try await positions.capture(locator, in: navigator) }
            catch is CancellationError where isScrolling { throw CancellationError() }
            catch { pointer = nil }
        case .settledPage:
            guard case .paginated(let paginated) = renderer else { return nil }
            let captured = try await positions.settledPage(in: paginated)
            locator = captured.locator
            pointer = captured.pointer
        case .origin(let location, let saved):
            locator = location
            let captured = try? await positions.capture(locator, in: navigator)
            pointer = captured ?? (locator.jsonString == saved?.locatorJSON ? saved?.xpointer : nil)
            updatedAt = saved?.updatedAt
        }
        try check { true }
        return Snapshot(position: ReadingPosition(progression: locator.locations.totalProgression ?? fallbackProgression,
            locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: updatedAt ?? Date()), locator: locator)
    }

    func move(to target: Target, isCurrent: @MainActor () -> Bool) async throws {
        try check(isCurrent)
        let navigator = renderer.navigator
        switch target {
        case .progression(let value):
            _ = try await positions.go(toProgression: value, in: navigator) { !self.closed && isCurrent() }
        case .link(let link):
            try await positions.go(to: link, in: navigator) { !self.closed && isCurrent() }
        case .checkpoint(let locator, let pointer):
            try await positions.restore(locator, pointer: pointer, in: navigator) { !self.closed && isCurrent() }
        }
        try check(isCurrent)
    }

    func remoteSnapshot(_ remote: RemoteProgress, approximate: Bool, isCurrent: @MainActor () -> Bool) async throws -> Snapshot {
        try check(isCurrent)
        let navigator = renderer.navigator
        let locator: Locator
        if approximate {
            guard let percentage = remote.percentage else { throw AppFailure("Couldn’t locate the position by percentage.") }
            locator = try await positions.go(toProgression: percentage, in: navigator) { !self.closed && isCurrent() }
        } else {
            guard let pointer = remote.progress else { throw AppFailure("No remote reading position is available.") }
            locator = try await positions.go(toPointer: pointer, in: navigator) { !self.closed && isCurrent() }
        }
        try check(isCurrent)
        let visible = currentLocation ?? locator
        return Snapshot(position: ReadingPosition(progression: remote.percentage ?? visible.locations.totalProgression ?? 0,
            locatorJSON: visible.jsonString, xpointer: approximate ? nil : remote.progress, updatedAt: Date()), locator: visible)
    }

    func contentsID() async -> UUID? {
        await positions.contentsID(in: renderer.navigator, contents: contents)
    }

    func canBeginPageTurn(isGesture: Bool) -> Bool {
        guard !closed, case .paginated(let navigator) = renderer else { return false }
        return !isGesture || (supportsScrolling && !navigator.settings.scroll && navigator.currentSelection == nil)
    }

    func towardLeft(forward: Bool) -> Bool {
        guard case .paginated(let navigator) = renderer else { return forward }
        return forward == (navigator.presentation.readingProgression == .ltr)
    }

    func movePage(towardLeft: Bool, isCurrent: @MainActor () -> Bool) async throws -> Bool {
        try check(isCurrent)
        guard case .paginated(let navigator) = renderer else { return false }
        let forward = towardLeft == (navigator.presentation.readingProgression == .ltr)
        let options = NavigatorGoOptions(animated: false)
        let moved = forward ? await navigator.goForward(options: options) : await navigator.goBackward(options: options)
        try check(isCurrent)
        return moved
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

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard case .paginated(let active) = renderer, (navigator as AnyObject) === active, active.currentSelection == nil else { return }
        emit(.tapped(point, active.view.bounds))
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { emit(.error(error)) }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard case .paginated(let active) = renderer, (navigator as AnyObject) === active else { return }
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
