import UIKit
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

/// Each chapter keeps its original document. Only the outer scroll view scrolls.
@MainActor final class ContinuousEPUBController: UIViewController, EPUBReadingNavigator, UIScrollViewDelegate {
    let publication: Publication
    private(set) var currentLocation: Locator?
    var onLocationChanged: ((Locator) -> Void)?
    var onScrollBegan: (() -> Void)?
    var onLinkActivated: ((Link) -> Void)?
    var onError: ((Error) -> Void)?
    var onContentTap: (() -> Void)?
    let scrollView = UIScrollView()
    private let server: ContinuousPublicationServer
    private let initialLocation: Locator?
    private var settings: ReaderSettings
    private var layout: ContinuousEPUBLayout
    private var chapterViews: [Int: ContinuousChapter] = [:]
    private var width: CGFloat = 0
    private var started = false
    private var closed = false
    private var navigating = false
    private var updatingLayout = false
    private var scrollInsets: UIEdgeInsets = .zero
    private var navigationRevision = 0
    private var startupTask: Task<Void, Never>?
    var isScrolling: Bool { scrollView.isDragging || scrollView.isDecelerating }

    init(publication: Publication, initialLocation: Locator?, settings: ReaderSettings) {
        self.publication = publication
        self.initialLocation = initialLocation
        self.settings = settings
        server = ContinuousPublicationServer(publication: publication)
        layout = ContinuousEPUBLayout(chapterCount: publication.readingOrder.count)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)
        applyBackground()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: ContinuousEPUBController, _: UITraitCollection) in
            controller.updateSettings(controller.settings)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        updateSettings(settings)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatingLayout = true
        defer { updatingLayout = false }
        scrollView.frame = view.bounds
        let newWidth = scrollView.bounds.width
        guard newWidth > 0 else { return }
        let changed = newWidth != width
        width = newWidth
        layoutChapters()
        if changed { for chapter in chapterViews.values { chapter.updateStyle(chapterStyle) } }
        if !started {
            started = true
            startupTask = Task { [weak self] in
                guard let self = self, let first = self.publication.readingOrder.first else { return }
                if let initial = self.initialLocation { _ = await self.go(to: initial) }
                else { _ = await self.go(to: first) }
            }
        }
    }

    func close() {
        closed = true
        startupTask?.cancel()
        scrollView.delegate = nil
        for index in Array(chapterViews.keys) { removeChapter(index) }
        server.close()
    }

    func cancelNavigation() {
        navigationRevision += 1
        navigating = false
        for chapter in chapterViews.values { chapter.cancelWaits() }
    }

    func updateSettings(_ settings: ReaderSettings) {
        self.settings = settings
        applyBackground()
        for chapter in chapterViews.values { chapter.updateStyle(chapterStyle) }
    }

    private var chapterStyle: ContinuousEPUBStyle {
        ContinuousEPUBStyle(settings: settings,
            dark: settings.theme.isDark ?? (traitCollection.userInterfaceStyle == .dark),
            fontsURL: server.baseURL.appendingPathComponent("_reader/fonts/"))
    }

    private func applyBackground() {
        let color = chapterStyle.backgroundColor
        view.backgroundColor = color
        scrollView.backgroundColor = color
    }

    private func startChapter(_ index: Int) {
        guard !closed, layout.chapters.contains(index), chapterViews[index] == nil else { return }
        do {
            let chapter = try ContinuousChapter(url: server.url(for: publication.readingOrder[index].href),
                server: server, style: chapterStyle)
            chapter.onEvent = { [weak self, weak chapter] event in
                guard let self, let chapter, !self.closed, self.chapterViews[index] === chapter else { return }
                switch event {
                case .measuredHeight(let height):
                    self.measuredHeight(index: index, height: height)
                case .contentTapped:
                    guard !self.navigating, !self.isScrolling else { return }
                    self.onContentTap?()
                case .linkActivated(let url):
                    self.linkActivated(url)
                case .failed(let error):
                    if !self.navigating, index == self.layout.visibleChapter(in: self.viewport) {
                        self.onError?(error)
                    }
                }
            }
            chapterViews[index] = chapter
            scrollView.addSubview(chapter.view)
            layoutChapters()
            chapter.load()
        } catch {
            onError?(error)
        }
    }

    private func removeChapter(_ index: Int) {
        chapterViews.removeValue(forKey: index)?.close()
    }

    private func retainChapters(target: Int? = nil) {
        guard !closed, !layout.chapters.isEmpty else { return }
        let viewport = viewport
        let index = target ?? layout.visibleChapter(in: viewport)
        let range = layout.retainedChapters(in: viewport, target: target)
        for i in Array(chapterViews.keys) where !range.contains(i) { removeChapter(i) }
        startChapter(index)
        for i in range where i != index { startChapter(i) }
    }

    private var viewport: ContinuousEPUBLayout.Viewport {
        .init(size: scrollView.bounds.size, offset: scrollView.contentOffset.y, insets: scrollInsets)
    }

    func updateScrollInsets(_ insets: UIEdgeInsets) {
        guard scrollInsets != insets else { return }
        let top = viewport.readingTop
        scrollInsets = insets
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        scrollView.verticalScrollIndicatorInsets = insets
        applyScrollPosition(layout.align(top, in: viewport))
    }

    private func applyScrollPosition(_ position: ContinuousEPUBLayout.ScrollPosition) {
        updatingLayout = true
        scrollView.contentSize = CGSize(width: width, height: layout.contentHeight)
        scrollView.contentInset = position.insets
        if scrollView.contentOffset.y != position.offset {
            scrollView.setContentOffset(CGPoint(x: 0, y: position.offset), animated: false)
        }
        layoutVisibleChapters()
        updatingLayout = false
    }

    private func layoutChapters() {
        scrollView.contentSize = CGSize(width: width, height: layout.contentHeight)
        layoutVisibleChapters()
    }

    private func layoutVisibleChapters() {
        let viewport = viewport
        for (index, chapter) in chapterViews {
            chapter.applyFrame(layout.frame(for: index, in: viewport))
        }
    }

    private func measuredHeight(index: Int, height: CGFloat) {
        let viewport = viewport
        guard let position = layout.measure(height, chapter: index, in: viewport) else { return }
        applyScrollPosition(position)
        if !navigating { retainChapters() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutVisibleChapters()
        guard started, !navigating, !closed, !updatingLayout else { return }
        retainChapters()
        reportLocation()
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { onScrollBegan?() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportLocation() }
    private func reportLocation() {
        guard !closed, !navigating, !layout.chapters.isEmpty else { return }
        let viewport = viewport
        let index = layout.visibleChapter(in: viewport)
        let link = publication.readingOrder[index]
        let progression = layout.progression(in: index, viewport: viewport)
        guard let href = AnyURL(string: link.href) else { return }
        let locator = Locator(href: href, mediaType: link.mediaType ?? .xhtml, title: link.title,
            locations: .init(progression: progression, totalProgression: (Double(index) + progression) / Double(layout.chapters.count)))
        currentLocation = locator
        onLocationChanged?(locator)
    }

    private func waitForChapter(_ index: Int, revision: Int) async throws -> (ContinuousChapter, ContinuousChapter.Document) {
        try Task.checkCancellation()
        startChapter(index)
        guard !closed else { throw CancellationError() }
        guard let chapter = chapterViews[index] else { throw AppFailure("Couldn’t open the chapter.") }
        let measurement = try await chapter.measure()
        guard isCurrent(chapter, measurement.document, at: index, revision: revision) else { throw CancellationError() }
        measuredHeight(index: index, height: measurement.height)
        guard isCurrent(chapter, measurement.document, at: index, revision: revision) else { throw CancellationError() }
        return (chapter, measurement.document)
    }

    private func isCurrent(_ chapter: ContinuousChapter, _ document: ContinuousChapter.Document, at index: Int, revision: Int) -> Bool {
        !closed && revision == navigationRevision && !Task.isCancelled &&
            chapterViews[index] === chapter && chapter.isCurrent(document)
    }

    func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        do {
            let index = currentLocation.flatMap { location in
                publication.readingOrder.firstIndex { EPUBPositionBridge.normalize($0.href) == EPUBPositionBridge.normalize(location.href.string) }
            } ?? layout.visibleChapter(in: viewport)
            let revision = navigationRevision
            let (chapter, document) = try await waitForChapter(index, revision: revision)
            let range = layout.readableRange(in: index, viewport: viewport)
            let prefix = "window.SimpleReaderViewport={top:\(range.lowerBound)-window.scrollY,bottom:\(range.upperBound)-window.scrollY};\n"
            let result = try await chapter.evaluateJavaScript(prefix + script, in: document)
            guard isCurrent(chapter, document, at: index, revision: revision) else { throw CancellationError() }
            return .success(result)
        } catch { return .failure(error) }
    }

    func locator(for anchor: EPUBTextAnchor, in link: Link) throws -> Locator {
        var locations: [String: Any] = [:]
        locations["continuousTextNodeIndex"] = anchor.textNodeIndex
        locations["continuousTextOffset"] = anchor.textOffset
        return try anchor.locator(in: link, additionalLocations: locations)
    }

    func go(to link: Link, options: NavigatorGoOptions) async -> Bool {
        let fragments = link.href.components(separatedBy: "#")
        var locations = Locator.Locations()
        if fragments.count > 1 { locations.fragments = [fragments.dropFirst().joined(separator: "#")] }
        guard let href = AnyURL(string: link.href) else { return false }
        return await go(to: Locator(href: href, mediaType: link.mediaType ?? .xhtml, locations: locations), options: options)
    }

    func go(to locator: Locator, options: NavigatorGoOptions) async -> Bool {
        guard !closed, !Task.isCancelled, let index = publication.readingOrder.firstIndex(where: {
            EPUBPositionBridge.normalize($0.href) == EPUBPositionBridge.normalize(locator.href.string)
        }) else { return false }
        cancelNavigation()
        let revision = navigationRevision
        navigating = true
        defer { if revision == navigationRevision { navigating = false } }
        do {
            if chapterViews[index]?.needsReload == true { removeChapter(index) }
            retainChapters(target: index)
            let (chapter, document) = try await waitForChapter(index, revision: revision)
            let locations = locator.locations.otherLocations
            let fragment = locator.locations.fragments.first ?? locator.href.string.components(separatedBy: "#").dropFirst().joined(separator: "#")
            var target: [String: Any] = ["selector": locations["cssSelector"] ?? "", "fragment": fragment,
                "highlight": locator.text.highlight ?? "", "progression": locator.locations.progression ?? 0]
            target["textNodeIndex"] = locations["continuousTextNodeIndex"]
            target["textOffset"] = locations["continuousTextOffset"]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: target), as: UTF8.self)
            let result = try await chapter.evaluateJavaScript("window.SimpleReaderContinuousOffset(\(json))", in: document)
            guard isCurrent(chapter, document, at: index, revision: revision) else { return false }
            let localY = result as? Double ?? 0
            applyScrollPosition(layout.align(chapter: index, at: CGFloat(localY), in: viewport))
            let progression = layout.progression(in: index, viewport: viewport)
            let total = (Double(index) + progression) / Double(layout.chapters.count)
            let location = locator.copy(locations: {
                $0.progression = progression
                $0.totalProgression = total
            })
            currentLocation = location
            onLocationChanged?(location)
            return true
        } catch is CancellationError { return false }
        catch {
            if !closed, revision == navigationRevision, !Task.isCancelled { onError?(error) }
            return false
        }
    }

    private func linkActivated(_ url: URL) {
        guard url.scheme == server.scheme, url.host == server.baseURL.host else { return }
        let path = url.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let href = path + (url.fragment(percentEncoded: true).map { "#" + $0 } ?? "")
        guard AnyURL(string: href) != nil else { return }
        onLinkActivated?(Link(href: href, mediaType: .xhtml))
    }
}

