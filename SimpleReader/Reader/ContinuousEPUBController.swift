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
    var onError: ((Error) -> Void)?
    var onContentTap: (() -> Void)?
    let scrollView = UIScrollView()
    private let server: ContinuousPublicationServer
    private let initialLocation: Locator?
    private var settings: ReaderSettings
    private var layout: ContinuousEPUBLayout
    private var webViews: [Int: WKWebView] = [:]
    private var loaded: Set<Int> = []
    private var failures: [Int: Error] = [:]
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
        if changed { for webView in webViews.values { applyStyle(to: webView) } }
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
        for webView in webViews.values {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "continuousChapterHeight")
            webView.superview?.removeFromSuperview()
        }
        webViews.removeAll()
        server.close()
    }

    func cancelNavigation() {
        navigationRevision += 1
        navigating = false
    }

    func updateSettings(_ settings: ReaderSettings) {
        self.settings = settings
        applyBackground()
        for webView in webViews.values { applyStyle(to: webView) }
    }

    private var dark: Bool { settings.theme.isDark ?? (traitCollection.userInterfaceStyle == .dark) }
    private var backgroundLevel: Int { dark ? 23 : 255 }

    private func applyBackground() {
        let color = UIColor(white: CGFloat(backgroundLevel) / 255, alpha: 1)
        view.backgroundColor = color
        scrollView.backgroundColor = color
        for webView in webViews.values { webView.backgroundColor = color }
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
        guard !closed, layout.chapters.contains(index), webViews[index] == nil else { return }
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
        webViews[index] = webView
        let clip = UIView()
        clip.clipsToBounds = true
        clip.addSubview(webView)
        scrollView.addSubview(clip)
        layoutChapters()
        webView.load(URLRequest(url: server.url(for: publication.readingOrder[index].href)))
    }

    private func retainChapters(target: Int? = nil) {
        guard !closed, !layout.chapters.isEmpty else { return }
        let viewport = viewport
        let index = target ?? layout.visibleChapter(in: viewport)
        let range = layout.retainedChapters(in: viewport, target: target)
        for i in Array(webViews.keys) where !range.contains(i) {
            webViews[i]?.stopLoading()
            webViews[i]?.navigationDelegate = nil
            webViews[i]?.configuration.userContentController.removeScriptMessageHandler(forName: "continuousChapterHeight")
            webViews[i]?.superview?.removeFromSuperview()
            webViews.removeValue(forKey: i)
            loaded.remove(i)
            failures.removeValue(forKey: i)
        }
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
        for (index, webView) in webViews {
            let frame = layout.frame(for: index, in: viewport)
            webView.superview?.frame = frame.clip
            webView.frame = frame.web
            if webView.scrollView.contentOffset.y != frame.offset {
                webView.scrollView.contentOffset = CGPoint(x: 0, y: frame.offset)
            }
        }
    }

    fileprivate func measuredHeight(index: Int, height: CGFloat, webView: WKWebView?) {
        guard !closed, let active = webViews[index], active === webView else { return }
        let viewport = viewport
        guard let position = layout.measure(height, chapter: index, in: viewport) else { return }
        applyScrollPosition(position)
        if !navigating { retainChapters() }
    }

    fileprivate func contentTapped(index: Int, webView: WKWebView?) {
        guard !closed, !navigating, !scrollView.isDragging, !scrollView.isDecelerating,
              let active = webViews[index], active === webView else { return }
        onContentTap?()
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

    private func waitForChapter(_ index: Int) async throws -> WKWebView {
        startChapter(index)
        for _ in 0..<400 {
            try Task.checkCancellation()
            guard !closed, let webView = webViews[index] else { throw CancellationError() }
            if let failure = failures[index] { throw failure }
            if loaded.contains(index) {
                let measured = try await webView.callAsyncJavaScript("await document.fonts.ready; return Math.ceil(Math.max(document.body.scrollHeight,document.body.getBoundingClientRect().height));", arguments: [:], in: nil, contentWorld: .page)
                if let height = measured as? Double { measuredHeight(index: index, height: CGFloat(height), webView: webView) }
                guard !closed, webViews[index] === webView else { throw CancellationError() }
                return webView
            }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw AppFailure("The chapter took too long to load. Try again.")
    }

    func evaluateJavaScript(_ script: String) async -> Result<Any, Error> {
        do {
            let index = currentLocation.flatMap { location in
                publication.readingOrder.firstIndex { EPUBPositionBridge.normalize($0.href) == EPUBPositionBridge.normalize(location.href.string) }
            } ?? layout.visibleChapter(in: viewport)
            let webView = try await waitForChapter(index)
            let range = layout.readableRange(in: index, viewport: viewport)
            let prefix = "window.SimpleReaderViewport={top:\(range.lowerBound)-window.scrollY,bottom:\(range.upperBound)-window.scrollY};\n"
            return .success(try await webView.evaluateJavaScript(prefix + script) as Any)
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
        guard !closed, let index = publication.readingOrder.firstIndex(where: {
            EPUBPositionBridge.normalize($0.href) == EPUBPositionBridge.normalize(locator.href.string)
        }) else { return false }
        navigationRevision += 1
        let revision = navigationRevision
        navigating = true
        defer { if revision == navigationRevision { navigating = false } }
        do {
            retainChapters(target: index)
            let webView = try await waitForChapter(index)
            guard revision == navigationRevision, !Task.isCancelled else { return false }
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
            let localY = try await webView.evaluateJavaScript(script) as? Double ?? 0
            guard !closed, revision == navigationRevision, !Task.isCancelled else { return false }
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
        catch { onError?(error); return false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let index = webViews.first(where: { $0.value === webView })?.key else { return }
        loaded.insert(index)
        failures.removeValue(forKey: index)
        applyStyle(to: webView)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error: error) }
    private func failed(_ webView: WKWebView, error: Error) {
        guard !closed, let index = webViews.first(where: { $0.value === webView })?.key else { return }
        failures[index] = error
        onError?(error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let index = webViews.first(where: { $0.value === webView })?.key else { return }
        loaded.remove(index)
        webView.reload()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        guard url.scheme == server.scheme, url.host == server.baseURL.host else { return }
        let href = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (url.fragment.map { "#" + $0 } ?? "")
        guard let target = AnyURL(string: href) else { return }
        onScrollBegan?()
        Task { [weak self] in guard let self = self else { return }; _ = await self.go(to: Locator(href: target, mediaType: .xhtml)) }
    }
}

@MainActor private final class ContinuousChapterMessages: NSObject, WKScriptMessageHandler {
    weak var owner: ContinuousEPUBController?
    init(owner: ContinuousEPUBController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let index = body["index"] as? Int else { return }
        if body["tap"] as? Bool == true { owner?.contentTapped(index: index, webView: message.webView) }
        else if let height = body["height"] as? Double {
            owner?.measuredHeight(index: index, height: CGFloat(height), webView: message.webView)
        }
    }
}

