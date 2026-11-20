import UIKit
import ReadiumShared

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
                do {
                    let locator = try self.initialLocation ?? EPUBReadingPosition.locator(for: first)
                    _ = try await self.navigate(to: locator, path: nil, isCurrent: { true })
                } catch is CancellationError {
                } catch {
                    self.onError?(error)
                }
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

    private func retainChapters() {
        guard !closed, !layout.chapters.isEmpty else { return }
        let viewport = viewport
        let index = layout.visibleChapter(in: viewport)
        let range = layout.retainedChapters(in: viewport)
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

    func evaluatePositionJavaScript(_ script: String, in href: String) async throws -> Any {
        guard let index = chapterIndex(for: href), chapterIndex(for: currentLocation?.href.string) == index else { throw CancellationError() }
        let revision = navigationRevision
        let (chapter, document) = try await waitForChapter(index, revision: revision)
        let range = layout.readableRange(in: index, viewport: viewport)
        let prefix = "window.SimpleReaderViewport={top:\(range.lowerBound)-window.scrollY,bottom:\(range.upperBound)-window.scrollY};\n"
        let result = try await chapter.evaluateJavaScript(prefix + script, in: document)
        guard isCurrent(chapter, document, at: index, revision: revision),
              chapterIndex(for: currentLocation?.href.string) == index else { throw CancellationError() }
        return result
    }

    private func chapterIndex(for href: String?) -> Int? {
        guard let href else { return nil }
        let resource = EPUBPositionBridge.normalize(href)
        return publication.readingOrder.firstIndex { EPUBPositionBridge.normalize($0.href) == resource }
    }

    @discardableResult
    func move(to anchor: EPUBReadingPosition.Target, isCurrent: @MainActor () -> Bool) async throws -> Locator {
        try await move(to: EPUBReadingPosition.chapterStart(anchor.resource), path: anchor.path, isCurrent: isCurrent)
    }

    @discardableResult
    func move(to locator: Locator, isCurrent: @MainActor () -> Bool) async throws -> Locator {
        try await move(to: locator, path: nil, isCurrent: isCurrent)
    }

    private func move(to locator: Locator, path: String?, isCurrent: @MainActor () -> Bool) async throws -> Locator {
        try check(isCurrent)
        startupTask?.cancel()
        return try await navigate(to: locator, path: path, isCurrent: isCurrent)
    }

    private func navigate(to locator: Locator, path: String?, isCurrent: @MainActor () -> Bool) async throws -> Locator {
        try check(isCurrent)
        guard let index = chapterIndex(for: locator.href.string) else { throw AppFailure("Couldn’t open the chapter.") }
        cancelNavigation()
        let revision = navigationRevision
        navigating = true
        defer {
            if revision == navigationRevision {
                navigating = false
                retainChapters()
            }
        }
        if chapterViews[index]?.needsReload == true { removeChapter(index) }
        let (chapter, document) = try await waitForChapter(index, revision: revision)
        try check(isCurrent)
        let script: String
        if let path {
            script = "SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(path)));"
        } else {
            script = try EPUBReadingPosition.continuousOffsetScript(for: locator)
        }
        let value = try await chapter.evaluateJavaScript(script, in: document)
        try check(isCurrent)
        guard self.isCurrent(chapter, document, at: index, revision: revision) else { throw CancellationError() }
        let destination: (locator: Locator, offset: Double)
        if path != nil {
            destination = try EPUBReadingPosition.continuousDestination(value, from: locator)
        } else {
            guard let offset = value as? Double, offset.isFinite else { throw AppFailure("Couldn’t jump to the selected position.") }
            destination = (locator, offset)
        }
        applyScrollPosition(layout.align(chapter: index, at: CGFloat(destination.offset), in: viewport))
        let progression = layout.progression(in: index, viewport: viewport)
        let total = (Double(index) + progression) / Double(layout.chapters.count)
        let location = destination.locator.copy(locations: {
            $0.progression = progression
            $0.totalProgression = total
        })
        currentLocation = location
        onLocationChanged?(location)
        return location
    }

    private func check(_ isCurrent: @MainActor () -> Bool) throws {
        try Task.checkCancellation()
        guard !closed, isCurrent() else { throw CancellationError() }
    }

    private func linkActivated(_ url: URL) {
        guard url.scheme == server.scheme, url.host == server.baseURL.host else { return }
        let path = url.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let href = path + (url.fragment(percentEncoded: true).map { "#" + $0 } ?? "")
        guard AnyURL(string: href) != nil else { return }
        onLinkActivated?(Link(href: href, mediaType: .xhtml))
    }
}

