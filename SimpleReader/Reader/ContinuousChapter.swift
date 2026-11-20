import UIKit
import WebKit

/// Owns one chapter document, including its WebKit callbacks and pending script work.
@MainActor final class ContinuousChapter: NSObject, WKNavigationDelegate {
    struct Document {
        fileprivate let navigation: WKNavigation
    }

    struct Measurement {
        let document: Document
        let height: CGFloat
    }

    enum Event {
        case measuredHeight(CGFloat), contentTapped, linkActivated(URL), failed(Error)
    }

    private enum State {
        case idle, loading(WKNavigation), loaded(WKNavigation), failed(Error)

        var navigation: WKNavigation? {
            switch self {
            case .loading(let navigation), .loaded(let navigation): return navigation
            case .idle, .failed: return nil
            }
        }
    }

    private enum JavaScript {
        case measure
        case evaluate(String, WKNavigation)
    }

    private struct JavaScriptResult {
        let navigation: WKNavigation
        let value: Any
    }

    private struct Wait {
        let script: JavaScript
        let continuation: CheckedContinuation<JavaScriptResult, Error>
        let timeout: Task<Void, Never>
    }

    private static let bootstrap: Result<String, Error> = Result {
        guard let url = Bundle.main.url(forResource: "ContinuousChapter", withExtension: "js") else {
            throw AppFailure("Couldn’t open the chapter.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    let view = UIView()
    var onEvent: ((Event) -> Void)?
    private let webView: WKWebView
    private let url: URL
    private var style: ContinuousEPUBStyle
    private var state = State.idle
    private weak var replacedNavigation: WKNavigation?
    private var waits: [UUID: Wait] = [:]
    private var closed = false
    private(set) var needsReload = false

    init(url: URL, server: ContinuousPublicationServer, style: ContinuousEPUBStyle) throws {
        self.url = url
        self.style = style
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(server, forURLScheme: server.scheme)
        let source = try "\(EPUBPositionBridge.source)\n\(Self.bootstrap.get())"
        let css = try EPUBPositionBridge.quoted(style.css)
        configuration.userContentController.addUserScript(WKUserScript(
            source: "\(source)(\(css));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(ContinuousChapterMessages(owner: self), name: "continuousChapterHeight")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = style.backgroundColor
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        view.clipsToBounds = true
        view.addSubview(webView)
    }

    func load() {
        guard !closed else { return }
        replacedNavigation = state.navigation
        replaceDocument(with: .idle)
        guard let navigation = webView.load(URLRequest(url: url)) else {
            fail(AppFailure("Couldn’t open the chapter."))
            return
        }
        state = .loading(navigation)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        cancelWaits()
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "continuousChapterHeight")
        view.removeFromSuperview()
    }

    func updateStyle(_ style: ContinuousEPUBStyle) {
        guard !closed else { return }
        self.style = style
        webView.backgroundColor = style.backgroundColor
        applyStyle()
    }

    func applyFrame(_ frame: ContinuousEPUBLayout.ChapterFrame) {
        view.frame = frame.clip
        webView.frame = frame.web
        if webView.scrollView.contentOffset.y != frame.offset {
            webView.scrollView.contentOffset = CGPoint(x: 0, y: frame.offset)
        }
    }

    func isCurrent(_ document: Document) -> Bool { !closed && isLoaded(document.navigation) }

    func measure() async throws -> Measurement {
        let result = try await run(.measure)
        guard let height = result.value as? Double else { throw AppFailure("Couldn’t open the chapter.") }
        return Measurement(document: Document(navigation: result.navigation), height: CGFloat(height))
    }

    func evaluateJavaScript(_ script: String, in document: Document) async throws -> Any {
        try await run(.evaluate(script, document.navigation)).value
    }

    func cancelWaits() {
        for id in Array(waits.keys) { finish(id, with: .failure(CancellationError())) }
    }

    private func applyStyle() {
        guard let css = try? EPUBPositionBridge.quoted(style.css) else { return }
        webView.evaluateJavaScript("window.SimpleReaderContinuousStyle?.(\(css));")
    }

    private func matches(_ candidate: URL?) -> Bool {
        guard let candidate else { return false }
        return candidate.scheme == url.scheme && candidate.host == url.host &&
            candidate.path(percentEncoded: true) == url.path(percentEncoded: true)
    }

    private func isLoaded(_ navigation: WKNavigation) -> Bool {
        guard case .loaded(let active) = state else { return false }
        return active === navigation
    }

    private func isLoading(_ navigation: WKNavigation) -> Bool {
        guard case .loading(let active) = state else { return false }
        return active === navigation
    }

    private func run(_ script: JavaScript) async throws -> JavaScriptResult {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else {
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

    private func replaceDocument(with state: State) {
        self.state = state
        needsReload = false
        // Measurements can follow a replacement load. Scripts target one concrete document.
        for (id, wait) in waits {
            if case .evaluate = wait.script { finish(id, with: .failure(CancellationError())) }
        }
    }

    private func execute(_ script: JavaScript, for id: UUID, in navigation: WKNavigation) {
        let completion: @MainActor @Sendable (Result<Any, Error>) -> Void = { [weak self] result in
            let finish: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, !self.closed, self.isLoaded(navigation) else { return }
                self.finish(id, with: result.map { JavaScriptResult(navigation: navigation, value: $0) })
            }
            if case .failure = result {
                // Process termination can fail JavaScript before a replacement load starts.
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
        needsReload = true
        finish(id, with: .failure(AppFailure("The chapter took too long to load. Try again.")))
    }

    private func finish(_ id: UUID, with result: Result<JavaScriptResult, Error>) {
        guard let wait = waits.removeValue(forKey: id) else { return }
        wait.timeout.cancel()
        wait.continuation.resume(with: result)
    }

    private func fail(_ error: Error) {
        state = .failed(error)
        needsReload = true
        for id in Array(waits.keys) { finish(id, with: .failure(error)) }
        onEvent?(.failed(error))
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !closed, message.webView === webView, message.frameInfo.isMainFrame,
              case .loaded = state, matches(message.frameInfo.request.url),
              let body = message.body as? [String: Any] else { return }
        if body["tap"] as? Bool == true { onEvent?(.contentTapped) }
        else if let height = body["height"] as? Double { onEvent?(.measuredHeight(CGFloat(height))) }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !closed, let navigation, navigation !== replacedNavigation, navigation !== state.navigation else { return }
        replaceDocument(with: .loading(navigation))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, let navigation, isLoading(navigation) else { return }
        guard matches(webView.url) else { fail(AppFailure("Couldn’t open the chapter.")); return }
        applyStyle()
        state = .loaded(navigation)
        needsReload = false
        for (id, wait) in waits { execute(wait.script, for: id, in: navigation) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard !closed, let navigation, isLoading(navigation) else { return }
        // WebKit can cancel a provisional load just before starting its replacement.
        if (error as? URLError)?.code == .cancelled { return }
        fail(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Waiting measurements keep their deadlines while the document is replaced.
        load()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if !closed { onEvent?(.linkActivated(url)) }
    }
}

@MainActor private final class ContinuousChapterMessages: NSObject, WKScriptMessageHandler {
    private weak var owner: ContinuousChapter?
    init(owner: ContinuousChapter) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}
