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

/// Each chapter keeps its original document. Only the outer scroll view scrolls.
@MainActor final class ContinuousEPUBController: UIViewController, EPUBReadingNavigator, UIScrollViewDelegate, WKNavigationDelegate {
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
    private var chapterViews: [Int: ChapterView] = [:]
    private var width: CGFloat = 0
    private var started = false
    private var closed = false
    private var navigating = false
    private var updatingLayout = false
    private var scrollInsets: UIEdgeInsets = .zero
    private var navigationRevision = 0
    private var startupTask: Task<Void, Never>?
    private lazy var messages = ContinuousChapterMessages(owner: self)
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
        if changed { for chapter in chapterViews.values { applyStyle(to: chapter.webView) } }
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
        for chapter in chapterViews.values { applyStyle(to: chapter.webView) }
    }

    private var dark: Bool { settings.theme.isDark ?? (traitCollection.userInterfaceStyle == .dark) }
    private var backgroundLevel: Int { dark ? 23 : 255 }

    private func applyBackground() {
        let color = UIColor(white: CGFloat(backgroundLevel) / 255, alpha: 1)
        view.backgroundColor = color
        scrollView.backgroundColor = color
        for chapter in chapterViews.values { chapter.webView.backgroundColor = color }
    }

    private var style: String {
        let level = backgroundLevel
        let background = "rgb(\(level),\(level),\(level))"
        let foreground = dark ? "#e8e8e8" : "#202020"
        let fonts = server.baseURL.appendingPathComponent("_reader/fonts/").absoluteString
        return """
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-Regular.ttf')}
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-It.ttf');font-style:italic}
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-Bold.ttf');font-weight:bold}
        @font-face {font-family:'Source Serif 4';src:url('\(fonts)SourceSerif4-BoldIt.ttf');font-style:italic;font-weight:bold}
        @font-face {font-family:'LXGW WenKai';src:url('\(fonts)LXGWWenKai-Regular.ttf')}
        html {height:auto!important;min-height:0!important;overflow:hidden!important;column-count:auto!important;column-width:auto!important;writing-mode:horizontal-tb!important;background:\(background)!important;color:\(foreground)!important;font-size:\(settings.fontSize)%!important;-webkit-text-size-adjust:100%}
        body {height:auto!important;min-height:0!important;overflow:visible!important;margin:0!important;padding:16px \(24 * settings.pageMargins)px!important;box-sizing:border-box!important;font-family:\(settings.font.cssStack)!important;line-height:\(settings.lineHeight)!important;writing-mode:horizontal-tb!important;color:inherit!important;background:transparent!important}
        body * {font-family:inherit!important;line-height:inherit!important}
        body pre,body code,body kbd,body samp {font-family:monospace!important}
        img,svg,video,object {max-width:100%!important;height:auto;box-sizing:border-box}
        table,pre {max-width:100%;overflow-wrap:anywhere} pre {white-space:pre-wrap}
        """
    }

    private func applyStyle(to webView: WKWebView) {
        guard let css = try? EPUBPositionBridge.quoted(style) else { return }
        webView.evaluateJavaScript("window.SimpleReaderContinuousStyle?.(\(css));")
    }

    private func startChapter(_ index: Int) {
        guard !closed, layout.chapters.contains(index), chapterViews[index] == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: server.scheme)
        configuration.userContentController.add(messages, name: "continuousChapterHeight")
        let css = (try? EPUBPositionBridge.quoted(style)) ?? "''"
        let script = """
        (() => {
          let style;
          let pending = false;
          let pointerStart;
          let dragged = false;
          let tapTimer;
          document.addEventListener('pointerdown', event => { clearTimeout(tapTimer);pointerStart={x:event.clientX,y:event.clientY};dragged=false; }, {passive:true});
          document.addEventListener('pointermove', event => {
            if(pointerStart && Math.hypot(event.clientX-pointerStart.x,event.clientY-pointerStart.y)>8) dragged=true;
          }, {passive:true});
          document.addEventListener('pointercancel', () => {dragged=true;pointerStart=undefined;}, {passive:true});
          document.addEventListener('click', event => {
            clearTimeout(tapTimer);
            if(dragged || event.defaultPrevented || event.detail>1 || window.getSelection()?.isCollapsed===false
                || event.target.closest('a,button,input,textarea,select,label,[contenteditable="true"],[role="button"]')
                || event.clientX<innerWidth*0.2 || event.clientX>innerWidth*0.8) return;
            tapTimer=setTimeout(() => {
              if(!dragged && window.getSelection()?.isCollapsed!==false)
                window.webkit.messageHandlers.continuousChapterHeight.postMessage({index:\(index),tap:true});
            },250);
          });
          function measure() {
            if (!document.body || pending) return;
            pending = true;
            requestAnimationFrame(() => {
              pending = false;
              const body = document.body;
              const height = Math.ceil(Math.max(body.scrollHeight, body.getBoundingClientRect().height));
              window.webkit.messageHandlers.continuousChapterHeight.postMessage({index:\(index),height});
            });
          }
          window.SimpleReaderContinuousStyle = css => {
            if (!document.body) return;
            if (!style) { style = document.createElement('style');style.dataset.simpleReaderInert='';document.head.append(style); }
            style.textContent = css;
            measure();
          };
          function start() {
            const viewport=document.createElement('meta');viewport.name='viewport';viewport.content='width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';document.head.append(viewport);
            window.SimpleReaderContinuousStyle(\(css));
            new ResizeObserver(measure).observe(document.body);
            window.addEventListener('load', measure);
            document.fonts?.ready.then(measure);
          }
          document.addEventListener('DOMContentLoaded', start, {once:true});
          if (document.readyState !== 'loading') start();
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let chapter = ChapterView(webView: webView, url: server.url(for: publication.readingOrder[index].href))
        chapterViews[index] = chapter
        let clip = UIView()
        clip.clipsToBounds = true
        clip.addSubview(webView)
        scrollView.addSubview(clip)
        layoutChapters()
        loadChapter(chapter, at: index)
    }

    private func loadChapter(_ chapter: ChapterView, at index: Int) {
        if !chapter.load() {
            failChapter(chapter, at: index, with: AppFailure("Couldn’t open the chapter."))
        }
    }

    private func removeChapter(_ index: Int) {
        guard let chapter = chapterViews.removeValue(forKey: index) else { return }
        chapter.cancelWaits()
        let webView = chapter.webView
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "continuousChapterHeight")
        webView.superview?.removeFromSuperview()
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
            let webView = chapter.webView
            let frame = layout.frame(for: index, in: viewport)
            webView.superview?.frame = frame.clip
            webView.frame = frame.web
            if webView.scrollView.contentOffset.y != frame.offset {
                webView.scrollView.contentOffset = CGPoint(x: 0, y: frame.offset)
            }
        }
    }

    fileprivate func measuredHeight(index: Int, height: CGFloat, webView: WKWebView?) {
        guard !closed, let active = chapterViews[index]?.webView, active === webView else { return }
        let viewport = viewport
        guard let position = layout.measure(height, chapter: index, in: viewport) else { return }
        applyScrollPosition(position)
        if !navigating { retainChapters() }
    }

    fileprivate func contentTapped(index: Int, webView: WKWebView?) {
        guard !closed, !navigating, !scrollView.isDragging, !scrollView.isDecelerating,
              let active = chapterViews[index]?.webView, active === webView else { return }
        onContentTap?()
    }

    fileprivate func isCurrentChapterFrame(_ url: URL?, at index: Int, webView: WKWebView?) -> Bool {
        guard let chapter = chapterViews[index], chapter.webView === webView else { return false }
        return chapter.isLoadedDocument && chapter.matches(url)
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

    private func waitForChapter(_ index: Int, revision: Int) async throws -> (ChapterView, WKNavigation) {
        try Task.checkCancellation()
        startChapter(index)
        guard let chapter = chapterViews[index], !closed else { throw CancellationError() }
        let document = try await chapter.run(.measure)
        guard isCurrent(chapter, document.navigation, at: index, revision: revision) else { throw CancellationError() }
        if let height = document.value as? Double {
            measuredHeight(index: index, height: CGFloat(height), webView: chapter.webView)
        }
        guard isCurrent(chapter, document.navigation, at: index, revision: revision) else { throw CancellationError() }
        return (chapter, document.navigation)
    }

    private func isCurrent(_ chapter: ChapterView, _ navigation: WKNavigation, at index: Int, revision: Int) -> Bool {
        !closed && revision == navigationRevision && !Task.isCancelled &&
            chapterViews[index] === chapter && chapter.isLoaded(navigation)
    }

    func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        do {
            let index = currentLocation.flatMap { location in
                publication.readingOrder.firstIndex { EPUBPositionBridge.normalize($0.href) == EPUBPositionBridge.normalize(location.href.string) }
            } ?? layout.visibleChapter(in: viewport)
            let revision = navigationRevision
            let (chapter, navigation) = try await waitForChapter(index, revision: revision)
            let range = layout.readableRange(in: index, viewport: viewport)
            let prefix = "window.SimpleReaderViewport={top:\(range.lowerBound)-window.scrollY,bottom:\(range.upperBound)-window.scrollY};\n"
            let result = try await chapter.run(.evaluate(prefix + script, navigation))
            guard isCurrent(chapter, navigation, at: index, revision: revision) else { throw CancellationError() }
            return .success(result.value)
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
            let (chapter, navigation) = try await waitForChapter(index, revision: revision)
            let locations = locator.locations.otherLocations
            let fragment = locator.locations.fragments.first ?? locator.href.string.components(separatedBy: "#").dropFirst().joined(separator: "#")
            var target: [String: Any] = ["selector": locations["cssSelector"] ?? "", "fragment": fragment,
                "highlight": locator.text.highlight ?? "", "progression": locator.locations.progression ?? 0]
            target["textNodeIndex"] = locations["continuousTextNodeIndex"]
            target["textOffset"] = locations["continuousTextOffset"]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: target), as: UTF8.self)
            let script = """
            (() => {
              const location=\(json);
              let element;
              if(location.selector) {try {element=document.querySelector(location.selector);} catch(_) {}}
              if(!element && location.fragment) {let id=location.fragment;try{id=decodeURIComponent(id)}catch(_){} element=document.getElementById(id);}
              if(element) {
                const node=element.childNodes[location.textNodeIndex];
                if(node?.nodeType===Node.TEXT_NODE && Number.isFinite(location.textOffset)) {
                  const range=document.createRange();const offset=Math.min(node.length,location.textOffset);
                  range.setStart(node,offset);range.setEnd(node,Math.min(node.length,offset+1));return window.scrollY + range.getBoundingClientRect().top;
                }
                if(location.highlight) {
                  const walker=document.createTreeWalker(element,NodeFilter.SHOW_TEXT);let node;
                  while(node=walker.nextNode()) {const index=node.data.indexOf(location.highlight);if(index>=0){const range=document.createRange();range.setStart(node,index);range.setEnd(node,Math.min(node.length,index+1));return window.scrollY + range.getBoundingClientRect().top;}}
                }
                return window.scrollY + element.getBoundingClientRect().top;
              }
              return Math.max(0,document.body.scrollHeight*location.progression);
            })();
            """
            let result = try await chapter.run(.evaluate(script, navigation))
            guard isCurrent(chapter, navigation, at: index, revision: revision) else { return false }
            let localY = result.value as? Double ?? 0
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let (_, chapter) = chapter(for: webView) else { return }
        chapter.didStart(navigation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, let (index, chapter) = chapter(for: webView), chapter.isLoading(navigation) else { return }
        guard chapter.matches(webView.url) else {
            failChapter(chapter, at: index, with: AppFailure("Couldn’t open the chapter."))
            return
        }
        applyStyle(to: webView)
        chapter.didLoad(navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }
    private func navigationFailed(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard let navigation, let (index, chapter) = chapter(for: webView), chapter.isLoading(navigation) else { return }
        // WebKit can cancel a provisional load just before starting its replacement.
        if (error as? URLError)?.code == .cancelled { return }
        failChapter(chapter, at: index, with: error)
    }
    private func chapter(for webView: WKWebView) -> (Int, ChapterView)? {
        guard !closed else { return nil }
        return chapterViews.first(where: { $0.value.webView === webView })
    }
    private func failChapter(_ chapter: ChapterView, at index: Int, with error: Error) {
        chapter.didFail(error)
        if !navigating, index == layout.visibleChapter(in: viewport) { onError?(error) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let (index, chapter) = chapter(for: webView) else { return }
        // Waiting callers can use the replacement document without extending their deadlines.
        loadChapter(chapter, at: index)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        guard !closed, chapterViews.values.contains(where: { $0.webView === webView }),
              url.scheme == server.scheme, url.host == server.baseURL.host else { return }
        let path = url.path(percentEncoded: true).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let href = path + (url.fragment(percentEncoded: true).map { "#" + $0 } ?? "")
        guard AnyURL(string: href) != nil else { return }
        onLinkActivated?(Link(href: href, mediaType: .xhtml))
    }

    private struct JavaScriptResult {
        let navigation: WKNavigation
        let value: Any
    }

    @MainActor private final class ChapterView {
        private enum State {
            case idle, loading(WKNavigation), loaded(WKNavigation), failed(Error)

            var navigation: WKNavigation? {
                switch self {
                case .loading(let navigation), .loaded(let navigation): return navigation
                case .idle, .failed: return nil
                }
            }
        }

        enum JavaScript {
            case measure
            case evaluate(String, WKNavigation)
        }

        private struct Wait {
            let script: JavaScript
            let continuation: CheckedContinuation<JavaScriptResult, Error>
            let timeout: Task<Void, Never>
        }

        let webView: WKWebView
        private let url: URL
        private var state = State.idle
        private weak var replacedNavigation: WKNavigation?
        private var waits: [UUID: Wait] = [:]
        private(set) var needsReload = false

        init(webView: WKWebView, url: URL) {
            self.webView = webView
            self.url = url
        }

        var isLoadedDocument: Bool {
            if case .loaded = state { return true }
            return false
        }

        func matches(_ candidate: URL?) -> Bool {
            guard let candidate else { return false }
            return candidate.scheme == url.scheme && candidate.host == url.host &&
                candidate.path(percentEncoded: true) == url.path(percentEncoded: true)
        }

        func load() -> Bool {
            replacedNavigation = state.navigation
            replaceDocument(with: .idle)
            guard let navigation = webView.load(URLRequest(url: url)) else { return false }
            state = .loading(navigation)
            return true
        }

        func didStart(_ navigation: WKNavigation) {
            guard navigation !== replacedNavigation, navigation !== state.navigation else { return }
            replaceDocument(with: .loading(navigation))
        }

        func isLoading(_ navigation: WKNavigation) -> Bool {
            guard case .loading(let active) = state else { return false }
            return active === navigation
        }

        func isLoaded(_ navigation: WKNavigation) -> Bool {
            guard case .loaded(let active) = state else { return false }
            return active === navigation
        }

        func run(_ script: JavaScript) async throws -> JavaScriptResult {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if case .failed(let error) = state {
                        continuation.resume(throwing: error)
                        return
                    }
                    if case .evaluate(_, let navigation) = script, !isLoaded(navigation) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(6_400)) } catch { return }
                        self?.timeOut(id)
                    }
                    waits[id] = Wait(script: script, continuation: continuation, timeout: timeout)
                    if case .loaded(let navigation) = state { execute(script, for: id, in: navigation) }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in self?.finish(id, with: .failure(CancellationError())) }
            }
        }

        func didLoad(_ navigation: WKNavigation) {
            state = .loaded(navigation)
            needsReload = false
            for (id, wait) in waits { execute(wait.script, for: id, in: navigation) }
        }

        func didFail(_ error: Error) {
            state = .failed(error)
            needsReload = true
            for id in Array(waits.keys) { finish(id, with: .failure(error)) }
        }

        func cancelWaits() {
            for id in Array(waits.keys) { finish(id, with: .failure(CancellationError())) }
        }

        private func replaceDocument(with state: State) {
            self.state = state
            needsReload = false
            // Measurements can follow a replacement load. A script targets one concrete document.
            for (id, wait) in waits {
                if case .evaluate = wait.script { finish(id, with: .failure(CancellationError())) }
            }
        }

        private func execute(_ script: JavaScript, for id: UUID, in navigation: WKNavigation) {
            let completion: @MainActor @Sendable (Result<Any, Error>) -> Void = { [weak self] result in
                let finish: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self, self.isLoaded(navigation) else { return }
                    self.finish(id, with: result.map { JavaScriptResult(navigation: navigation, value: $0) })
                }
                if case .failure = result {
                    // Process termination can fail JavaScript before the delegate starts a replacement load.
                    DispatchQueue.main.async(execute: finish)
                } else {
                    finish()
                }
            }
            switch script {
            case .measure:
                webView.callAsyncJavaScript("""
                    await document.fonts.ready;
                    return Math.ceil(Math.max(document.body.scrollHeight, document.body.getBoundingClientRect().height));
                    """, in: nil, in: .page, completionHandler: completion)
            case .evaluate(let source, _):
                webView.evaluateJavaScript(source, in: nil, in: .page, completionHandler: completion)
            }
        }

        private func timeOut(_ id: UUID) {
            guard waits[id] != nil else { return }
            let error = AppFailure("The chapter took too long to load. Try again.")
            needsReload = true
            finish(id, with: .failure(error))
        }

        private func finish(_ id: UUID, with result: Result<JavaScriptResult, Error>) {
            guard let wait = waits.removeValue(forKey: id) else { return }
            wait.timeout.cancel()
            wait.continuation.resume(with: result)
        }
    }
}

@MainActor private final class ContinuousChapterMessages: NSObject, WKScriptMessageHandler {
    weak var owner: ContinuousEPUBController?
    init(owner: ContinuousEPUBController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let index = body["index"] as? Int, let owner,
              owner.isCurrentChapterFrame(message.frameInfo.request.url, at: index, webView: message.webView) else { return }
        if body["tap"] as? Bool == true { owner.contentTapped(index: index, webView: message.webView) }
        else if let height = body["height"] as? Double {
            owner.measuredHeight(index: index, height: CGFloat(height), webView: message.webView)
        }
    }
}

