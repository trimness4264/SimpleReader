import UIKit
import WebKit

/// Keeps Readium's native scroll hierarchy and drag preview out of the reader container.
@MainActor final class ReadiumPageTurnSurface {
    enum Completion {
        case navigate(animate: Bool)
        case complete(committed: Bool)
    }

    private struct Drag {
        let webView: WKWebView
        let pageOrigin: CGPoint
        let chapterScroll: UIScrollView?
        let chapterOrigin: CGPoint
        let style: PageTurnStyle
        let curl: PageCurlView?
        var scroll: UIScrollView?
        var origin: CGPoint
        var destination: CGPoint
        var crossesChapter = false
        var translation = CGPoint.zero
    }

    private weak var content: UIView?
    private weak var viewport: UIView?
    private let isFixedLayout: Bool
    private var drag: Drag?
    private var chapterPreviewTask: Task<Void, Never>?
    private let registeredPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()

    init(content: UIView, viewport: UIView, isFixedLayout: Bool) {
        self.content = content
        self.viewport = viewport
        self.isFixedLayout = isFixedLayout
    }

    func allowsDrag(style: PageTurnStyle) -> Bool {
        guard isFixedLayout else { return true }
        guard style == .curl, let content, let viewport,
              let scroll = Self.presentedWebView(in: content, viewport: viewport)?.scrollView else { return false }
        return scroll.zoomScale <= scroll.minimumZoomScale * 1.01
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

    func beginDrag(style: PageTurnStyle) {
        guard let content, let viewport,
              let web = Self.presentedWebView(in: content, viewport: viewport) else { return }
        var ancestor = web.superview
        var chapter: UIScrollView?
        while let parent = ancestor, parent !== viewport {
            if let scroll = parent as? UIScrollView { chapter = scroll; break }
            ancestor = parent.superview
        }
        let origin = web.scrollView.contentOffset
        let curl = style == .curl && !UIAccessibility.isReduceMotionEnabled ? PageCurlView.capture(content, in: viewport) : nil
        drag = Drag(webView: web, pageOrigin: origin, chapterScroll: chapter,
            chapterOrigin: chapter?.contentOffset ?? .zero, style: style, curl: curl, origin: origin, destination: origin)
    }

    func updateDrag(translation: CGPoint) {
        guard var drag else { return }
        let wasTowardLeft = drag.translation.x < 0
        drag.translation = translation
        let towardLeft = translation.x < 0
        let direction: CGFloat = towardLeft ? 1 : -1
        let page = drag.webView.scrollView
        let destination = CGPoint(x: drag.pageOrigin.x + direction * page.bounds.width, y: drag.pageOrigin.y)
        let previousScroll = drag.scroll
        if !isFixedLayout && canDisplay(offset: destination, in: page) {
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
            drag.crossesChapter = false
        }
        if previousScroll !== drag.scroll { restoreOffsets(drag) }
        content?.transform = .identity
        if drag.style == .curl && UIAccessibility.isReduceMotionEnabled {
            restoreOffsets(drag)
            drag.curl?.show(0, towardLeft: towardLeft)
        } else if let curl = drag.curl {
            if let scroll = drag.scroll {
                // Keep the adjacent page still while the captured paper reveals it.
                if scroll.contentOffset != drag.destination { scroll.contentOffset = drag.destination }
                let progress = min(abs(translation.x) / scroll.bounds.width, 1)
                if curl.progress != progress || wasTowardLeft != towardLeft { curl.show(progress, towardLeft: towardLeft) }
            } else if curl.progress > 0 {
                curl.show(0, towardLeft: towardLeft)
            }
        } else if let scroll = drag.scroll {
            let distance = min(abs(translation.x), scroll.bounds.width)
            scroll.setContentOffset(CGPoint(x: drag.origin.x + direction * distance, y: drag.origin.y), animated: false)
        } else if !UIAccessibility.isReduceMotionEnabled {
            let resistance = translation.x / (1 + abs(translation.x) / 36)
            content?.transform = CGAffineTransform(translationX: resistance, y: 0)
        }
        self.drag = drag
        let previewsChapter = drag.crossesChapter || (drag.scroll == nil && drag.destination != drag.origin)
        watchChapterPreview(drag.curl != nil && previewsChapter && translation.x != 0 && !UIAccessibility.isReduceMotionEnabled)
    }

    private func watchChapterPreview(_ enabled: Bool) {
        guard enabled else {
            chapterPreviewTask?.cancel()
            chapterPreviewTask = nil
            return
        }
        guard chapterPreviewTask == nil else { return }
        // Readium lays out the chapter strip as each preload finishes, resetting its offset to the current chapter.
        chapterPreviewTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(32)) }
                catch { return }
                guard !Task.isCancelled, let self, let translation = self.drag?.translation else { return }
                self.updateDrag(translation: translation)
            }
        }
    }

    func finishDrag(commit: Bool, towardLeft: Bool, velocity: CGFloat, isCurrent: @MainActor () -> Bool,
                    capturePreview: () -> Void) async -> Completion {
        watchChapterPreview(false)
        guard let drag else { return commit ? .navigate(animate: true) : .complete(committed: false) }
        let reducedCurl = drag.style == .curl && UIAccessibility.isReduceMotionEnabled
        if let curl = drag.curl, !reducedCurl {
            if let scroll = drag.scroll {
                let target: CGFloat = commit ? 1 : 0
                let origin = curl.progress
                let distance = abs(target - origin) * scroll.bounds.width
                await animatePageTurnFrames(duration: settlingDuration(distance, velocity: velocity), isCurrent: isCurrent) { fraction in
                    if scroll.contentOffset != drag.destination { scroll.contentOffset = drag.destination }
                    curl.show(origin + (target - origin) * fraction, towardLeft: towardLeft)
                }
                if !commit, isCurrent() { restoreOffsets(drag) }
            }
        } else if !(reducedCurl && drag.crossesChapter) {
            await settle(drag, target: commit ? drag.destination : drag.origin, velocity: velocity, isCurrent: isCurrent)
        }
        guard isCurrent() else { return .complete(committed: false) }
        if commit, drag.crossesChapter {
            // Hold the revealed chapter over the viewport while Readium updates its index from the origin.
            if !reducedCurl { capturePreview() }
            restoreOffsets(drag)
            endDrag()
            return .navigate(animate: false)
        }
        if commit, drag.scroll == nil, drag.destination != drag.origin {
            endDrag()
            return .navigate(animate: true)
        }
        return .complete(committed: commit && drag.scroll != nil)
    }

    func endDrag() {
        watchChapterPreview(false)
        drag?.curl?.removeFromSuperview()
        drag = nil
    }

    func cancelDrag() {
        guard let drag else { return }
        restoreOffsets(drag)
        content?.transform = .identity
        endDrag()
    }

    private func restoreOffsets(_ drag: Drag) {
        if drag.webView.scrollView.contentOffset != drag.pageOrigin {
            drag.webView.scrollView.contentOffset = drag.pageOrigin
        }
        if let chapter = drag.chapterScroll, chapter.contentOffset != drag.chapterOrigin {
            chapter.contentOffset = drag.chapterOrigin
        }
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
        let duration = settlingDuration(distance, velocity: velocity)
        // Move actual WebKit offsets so DOM capture agrees with the visible page.
        await animatePageTurnFrames(duration: duration, isCurrent: isCurrent) { fraction in
            UIView.performWithoutAnimation {
                drag.scroll?.setContentOffset(CGPoint(x: origin.x + (target.x - origin.x) * fraction,
                    y: origin.y + (target.y - origin.y) * fraction), animated: false)
                self.content?.transform = CGAffineTransform(translationX: transform.tx * (1 - fraction),
                    y: transform.ty * (1 - fraction))
            }
        }
    }

    private func settlingDuration(_ distance: CGFloat, velocity: CGFloat) -> TimeInterval {
        min(0.4, max(0.16, distance / max(abs(velocity), 900)))
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
