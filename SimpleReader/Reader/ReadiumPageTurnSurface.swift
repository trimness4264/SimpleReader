import UIKit
import WebKit

/// Keeps Readium's native scroll hierarchy and drag preview out of the reader container.
@MainActor final class ReadiumPageTurnSurface {
    enum Completion {
        case navigate
        case complete(committed: Bool)
    }

    private struct Drag {
        let webView: WKWebView
        let pageOrigin: CGPoint
        let chapterScroll: UIScrollView?
        let chapterOrigin: CGPoint
        var scroll: UIScrollView?
        var origin: CGPoint
        var destination: CGPoint
        var crossesChapter = false
    }

    private weak var content: UIView?
    private weak var viewport: UIView?
    private var drag: Drag?
    private let registeredPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()

    init(content: UIView, viewport: UIView) {
        self.content = content
        self.viewport = viewport
    }

    func registerNativePans(requiringToFail gesture: UIPanGestureRecognizer) {
        guard let content else { return }
        registerPans(in: content, requiringToFail: gesture)
    }

    private func registerPans(in content: UIView, requiringToFail gesture: UIPanGestureRecognizer) {
        if let scroll = content as? UIScrollView {
            let pan = scroll.panGestureRecognizer
            if !registeredPans.contains(pan) {
                registeredPans.add(pan)
                pan.require(toFail: gesture)
            }
        }
        for child in content.subviews { registerPans(in: child, requiringToFail: gesture) }
    }

    func beginDrag() {
        guard let content, let viewport,
              let web = Self.presentedWebView(in: content, viewport: viewport) else { return }
        var ancestor = web.superview
        var chapter: UIScrollView?
        while let parent = ancestor, parent !== viewport {
            if let scroll = parent as? UIScrollView { chapter = scroll; break }
            ancestor = parent.superview
        }
        let origin = web.scrollView.contentOffset
        drag = Drag(webView: web, pageOrigin: origin, chapterScroll: chapter,
            chapterOrigin: chapter?.contentOffset ?? .zero, origin: origin, destination: origin)
    }

    func updateDrag(translation: CGPoint) {
        guard var drag else { return }
        let direction: CGFloat = translation.x < 0 ? 1 : -1
        let page = drag.webView.scrollView
        let destination = CGPoint(x: drag.pageOrigin.x + direction * page.bounds.width, y: drag.pageOrigin.y)
        page.setContentOffset(drag.pageOrigin, animated: false)
        drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        content?.transform = .identity
        if canDisplay(offset: destination, in: page) {
            drag.scroll = page
            drag.origin = drag.pageOrigin
            drag.destination = destination
            drag.crossesChapter = false
        } else if let chapter = drag.chapterScroll {
            let next = CGPoint(x: drag.chapterOrigin.x + direction * chapter.bounds.width, y: drag.chapterOrigin.y)
            let canDisplayNext = canDisplay(offset: next, in: chapter)
            drag.scroll = canDisplayNext && hasLoadedChapter(at: next, in: chapter) ? chapter : nil
            drag.origin = drag.chapterOrigin
            drag.destination = canDisplayNext ? next : drag.origin
            drag.crossesChapter = drag.scroll != nil
        } else {
            drag.scroll = nil
            drag.origin = drag.pageOrigin
            drag.destination = drag.origin
        }
        if let scroll = drag.scroll {
            let distance = min(abs(translation.x), scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: drag.origin.x + direction * distance, y: drag.origin.y), animated: false)
        } else if !UIAccessibility.isReduceMotionEnabled {
            let resistance = translation.x / (1 + abs(translation.x) / 36)
            content?.transform = CGAffineTransform(translationX: resistance, y: 0)
        }
        self.drag = drag
    }

    func finishDrag(commit: Bool, velocity: CGFloat, isCurrent: @MainActor () -> Bool,
                    capturePreview: () -> Bool) async -> Completion {
        guard let drag else { return commit ? .navigate : .complete(committed: false) }
        await settle(drag, target: commit ? drag.destination : drag.origin, velocity: velocity, isCurrent: isCurrent)
        guard isCurrent() else { return .complete(committed: false) }
        if commit, drag.scroll != nil, drag.crossesChapter, capturePreview() {
            drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        }
        if commit && (drag.crossesChapter || drag.scroll == nil && drag.destination != drag.origin) {
            // Readium navigation takes ownership after the native preview settles.
            self.drag = nil
            return .navigate
        }
        return .complete(committed: commit && drag.scroll != nil)
    }

    func endDrag() { drag = nil }

    func cancelDrag() {
        guard let drag else { return }
        drag.webView.scrollView.setContentOffset(drag.pageOrigin, animated: false)
        drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        content?.transform = .identity
        self.drag = nil
    }

    func waitForContent(isCurrent: @MainActor () -> Bool) async throws {
        guard let content, let viewport else { throw CancellationError() }
        // Readium resumes navigation before unhiding a cold chapter's scroll view.
        // Observe UIKit visibility instead of guessing a rendering delay.
        for _ in 0..<120 {
            guard isCurrent(), viewport.window != nil else { throw CancellationError() }
            if Self.presentedWebView(in: content, viewport: viewport) != nil { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw NSError(domain: "Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Chapter content isn’t visible yet. Try again.")])
    }

    private func settle(_ drag: Drag, target: CGPoint, velocity: CGFloat,
                        isCurrent: @MainActor () -> Bool) async {
        let origin = drag.scroll?.contentOffset ?? drag.origin
        let transform = content?.transform ?? .identity
        let distance = abs(origin.x - target.x)
        let duration = min(0.4, max(0.16, distance / max(abs(velocity), 900)))
        let start = CACurrentMediaTime()
        // Move actual WebKit offsets so DOM capture agrees with the visible page.
        while isCurrent() {
            let progress = UIAccessibility.isReduceMotionEnabled ? 1 : min(1, (CACurrentMediaTime() - start) / duration)
            let fraction = CGFloat(1 - pow(1 - progress, 3))
            UIView.performWithoutAnimation {
                drag.scroll?.setContentOffset(CGPoint(x: origin.x + (target.x - origin.x) * fraction,
                    y: origin.y + (target.y - origin.y) * fraction), animated: false)
                self.content?.transform = CGAffineTransform(translationX: transform.tx * (1 - fraction),
                    y: transform.ty * (1 - fraction))
            }
            if progress >= 1 { return }
            do { try await Task.sleep(nanoseconds: 16_000_000) }
            catch { return }
        }
    }

    private func canDisplay(offset: CGPoint, in scroll: UIScrollView) -> Bool {
        offset.x >= -scroll.adjustedContentInset.left - 1
            && offset.x <= scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right + 1
    }

    static func presentedWebView(in content: UIView, viewport: UIView) -> WKWebView? {
        findWebView(in: content) { web in
            let visible = web.convert(web.bounds, to: viewport).intersection(viewport.bounds)
            return visible.width > viewport.bounds.width / 2 && visible.height > viewport.bounds.height / 2
                && web.scrollView.alpha > 0.99 && !web.isLoading
        }
    }

    private func hasLoadedChapter(at offset: CGPoint, in scroll: UIScrollView) -> Bool {
        let target = CGRect(origin: offset, size: scroll.bounds.size)
        return scroll.subviews.contains { content in
            Self.findWebView(in: content, matching: { web in
                let overlap = web.convert(web.bounds, to: scroll).intersection(target)
                return overlap.width > target.width / 2 && web.scrollView.alpha > 0.99 && !web.isLoading
            }) != nil
        }
    }

    private static func findWebView(in content: UIView, matching predicate: (WKWebView) -> Bool) -> WKWebView? {
        guard !content.isHidden, content.alpha > 0.99 else { return nil }
        if let web = content as? WKWebView { return predicate(web) ? web : nil }
        for child in content.subviews {
            if let web = findWebView(in: child, matching: predicate) { return web }
        }
        return nil
    }
}
