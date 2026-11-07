import UIKit
import PDFKit
import WebKit

@MainActor protocol ReaderPageTurnDelegate: AnyObject {
    func canBeginPageTurn(isGesture: Bool) -> Bool
    func pageTurnWillBegin()
    func movePage(towardLeft: Bool) async throws -> Bool
    func pageTurnDidFinish(committed: Bool, error: Error?) async
}

private final class ReaderContainerView: UIView {
    var onSizeWillChange: (() -> Void)?

    override var frame: CGRect {
        willSet {
            if frame.size != newValue.size { onSizeWillChange?() }
        }
    }

    override var bounds: CGRect {
        willSet {
            if bounds.size != newValue.size { onSizeWillChange?() }
        }
    }
}

@MainActor final class ReaderContainerController: UIViewController, UIGestureRecognizerDelegate {
    private var appeared = false
    private var layoutSize: CGSize = .zero
    private var layoutChanged = false
    private var transitioning = false
    private var pageTransitionRevision = 0
    private var pageAnimator: UIViewPropertyAnimator?
    private var pageSnapshot: UIView?
    private var pageContent: UIView?
    private var committedPreview = false
    private struct PageDrag {
        let webView: WKWebView
        let pageOrigin: CGPoint
        let chapterScroll: UIScrollView?
        let chapterOrigin: CGPoint
        var scroll: UIScrollView?
        var origin: CGPoint
        var destination: CGPoint
        var crossesChapter = false
    }
    private var pageDrag: PageDrag?
    private let registeredPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    var onLayout: ((CGSize, UIUserInterfaceIdiom) -> Void)?
    var onLayoutWillChange: (() -> Void)?
    var onLayoutDidChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    weak var pageTurnDelegate: ReaderPageTurnDelegate?
    private(set) var isTurningPage = false
    private lazy var pageTurnPan = UIPanGestureRecognizer(target: self, action: #selector(handlePageTurn(_:)))

    override func loadView() {
        let surface = ReaderContainerView()
        surface.onSizeWillChange = { [weak self] in
            self?.layoutChanged = true
            self?.onLayoutWillChange?()
        }
        view = surface
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: ReaderContainerController, _: UITraitCollection) in
                controller.onAppearanceChange?()
            }
        }
        pageTurnPan.maximumNumberOfTouches = 1
        pageTurnPan.delegate = self
        view.addGestureRecognizer(pageTurnPan)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0), previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            onAppearanceChange?()
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pageTurnPan && beginPageTurn(translation: pageTurnPan.translation(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pageTurnPan, pageTurnDelegate?.canBeginPageTurn(isGesture: true) == true else { return false }
        if let content = children.first?.view { registerPagePans(in: content) }
        return true
    }

    private func registerPagePans(in content: UIView) {
        if let scroll = content as? UIScrollView {
            let pan = scroll.panGestureRecognizer
            if !registeredPans.contains(pan) {
                registeredPans.add(pan)
                pan.require(toFail: pageTurnPan)
            }
        }
        for child in content.subviews { registerPagePans(in: child) }
    }

    func beginPageTurn(translation: CGPoint) -> Bool {
        guard abs(translation.x) > abs(translation.y), beginTurn(isGesture: true) else { return false }
        if let web = visibleWebView(in: children.first?.view ?? view) {
            var ancestor = web.superview
            var chapter: UIScrollView?
            while let parent = ancestor, parent !== view {
                if let scroll = parent as? UIScrollView { chapter = scroll; break }
                ancestor = parent.superview
            }
            let origin = web.scrollView.contentOffset
            pageDrag = PageDrag(webView: web, pageOrigin: origin, chapterScroll: chapter,
                                chapterOrigin: chapter?.contentOffset ?? .zero,
                                origin: origin, destination: origin)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    @objc func handlePageTurn(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            updatePageTurn(translation: gesture.translation(in: view))
        case .ended:
            finishPageTurn(translation: gesture.translation(in: view), velocity: gesture.velocity(in: view))
        case .cancelled, .failed:
            finishPageTurn(translation: .zero)
        default:
            break
        }
    }

    func finishPageTurn(translation: CGPoint, velocity: CGPoint = .zero) {
        guard isTurningPage else { return }
        let projected = translation.x + velocity.x * 0.12
        let crossedThreshold = abs(projected) >= max(32, view.bounds.width * 0.2)
        let quickSwipe = abs(translation.x) >= 8 && abs(velocity.x) >= 450
        let commit = translation.x * projected > 0 && (crossedThreshold || quickSwipe)
        updatePageTurn(translation: translation)
        view.isUserInteractionEnabled = false
        let revision = pageTransitionRevision
        guard let drag = pageDrag else {
            Task { [weak self] in
                guard let self = self, revision == self.pageTransitionRevision else { return }
                if commit { await self.performPageTurn(towardLeft: projected < 0, revision: revision) }
                else { await self.completePageTurn(committed: false, revision: revision) }
            }
            return
        }
        Task { [weak self] in
            guard let self = self, revision == self.pageTransitionRevision else { return }
            let target = commit ? drag.destination : drag.origin
            await self.settlePageDrag(drag, target: target, velocity: velocity.x)
            guard revision == self.pageTransitionRevision else { return }
            if commit, drag.scroll != nil, drag.crossesChapter,
               let content = self.children.first?.view,
               let snapshot = content.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = content.convert(content.bounds, to: self.view)
                snapshot.isUserInteractionEnabled = true
                self.view.addSubview(snapshot)
                self.pageSnapshot = snapshot
                self.pageContent = content
                self.committedPreview = true
                drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
            }
            if commit && (drag.crossesChapter || drag.scroll == nil && drag.destination != drag.origin) {
                self.pageDrag = nil
                await self.performPageTurn(towardLeft: projected < 0, revision: revision)
            } else {
                await self.completePageTurn(committed: commit && drag.scroll != nil, revision: revision)
            }
        }
    }

    /// Buttons and gestures share the same begin, completion, and cancellation ownership.
    func turnPage(towardLeft: Bool) async {
        guard beginTurn(isGesture: false) else { return }
        await performPageTurn(towardLeft: towardLeft, revision: pageTransitionRevision)
    }

    private func beginTurn(isGesture: Bool) -> Bool {
        guard !isTurningPage, pageSnapshot == nil,
              pageTurnDelegate?.canBeginPageTurn(isGesture: isGesture) == true else { return false }
        isTurningPage = true
        pageTurnDelegate?.pageTurnWillBegin()
        return true
    }

    private func performPageTurn(towardLeft: Bool, revision: Int) async {
        guard revision == pageTransitionRevision else { return }
        view.isUserInteractionEnabled = false
        var failure: Error?
        let moved = await animatePageTurn(direction: towardLeft ? 1 : -1) {
            do {
                guard revision == self.pageTransitionRevision,
                      try await self.pageTurnDelegate?.movePage(towardLeft: towardLeft) == true,
                      revision == self.pageTransitionRevision else { return false }
                if !self.children.isEmpty { try await self.waitForEPUBContent() }
                return revision == self.pageTransitionRevision
            } catch is CancellationError {
                return false
            } catch {
                failure = error
                return false
            }
        }
        await completePageTurn(committed: moved, error: failure, revision: revision)
    }

    private func completePageTurn(committed: Bool, error: Error? = nil, revision: Int) async {
        guard revision == pageTransitionRevision else { return }
        // Do not unlock native pans until the settled position has been captured.
        await pageTurnDelegate?.pageTurnDidFinish(committed: committed, error: error)
        guard revision == pageTransitionRevision else { return }
        pageDrag = nil
        clearPageAnimation()
        view.isUserInteractionEnabled = true
        isTurningPage = false
    }

    func updatePageTurn(translation: CGPoint) {
        guard var drag = pageDrag else { return }
        let direction: CGFloat = translation.x < 0 ? 1 : -1
        let page = drag.webView.scrollView
        let destination = CGPoint(x: drag.pageOrigin.x + direction * page.bounds.width, y: drag.pageOrigin.y)
        page.setContentOffset(drag.pageOrigin, animated: false)
        drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        pageContent?.transform = .identity
        if canDisplay(offset: destination, in: page) {
            drag.scroll = page
            drag.origin = drag.pageOrigin
            drag.destination = destination
            drag.crossesChapter = false
        } else if let chapter = drag.chapterScroll {
            let next = CGPoint(x: drag.chapterOrigin.x + direction * chapter.bounds.width, y: drag.chapterOrigin.y)
            drag.scroll = canDisplay(offset: next, in: chapter) && hasLoadedChapter(at: next, in: chapter) ? chapter : nil
            drag.origin = drag.chapterOrigin
            drag.destination = canDisplay(offset: next, in: chapter) ? next : drag.origin
            drag.crossesChapter = drag.scroll != nil
        } else {
            drag.scroll = nil
            drag.origin = drag.pageOrigin
            drag.destination = drag.origin
        }
        if let scroll = drag.scroll {
            let width = scroll.bounds.width
            let distance = min(abs(translation.x), width)
            scroll.setContentOffset(CGPoint(x: drag.origin.x + direction * distance, y: drag.origin.y), animated: false)
        } else if let content = children.first?.view, !UIAccessibility.isReduceMotionEnabled {
            pageContent = content
            let resistance = translation.x / (1 + abs(translation.x) / 36)
            content.transform = CGAffineTransform(translationX: resistance, y: 0)
        }
        pageDrag = drag
    }

    private func canDisplay(offset: CGPoint, in scroll: UIScrollView) -> Bool {
        offset.x >= -scroll.adjustedContentInset.left - 1
            && offset.x <= scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right + 1
    }

    private func visibleWebView(in content: UIView) -> WKWebView? {
        guard !content.isHidden, content.alpha > 0.99 else { return nil }
        if let web = content as? WKWebView {
            let visible = web.convert(web.bounds, to: view).intersection(view.bounds)
            return visible.width > view.bounds.width / 2 && visible.height > view.bounds.height / 2 ? web : nil
        }
        return content.subviews.lazy.compactMap { self.visibleWebView(in: $0) }.first
    }

    private func hasLoadedChapter(at offset: CGPoint, in scroll: UIScrollView) -> Bool {
        let target = CGRect(origin: offset, size: scroll.bounds.size)
        func loaded(in content: UIView) -> Bool {
            guard !content.isHidden, content.alpha > 0.99 else { return false }
            if let web = content as? WKWebView {
                let overlap = web.convert(web.bounds, to: scroll).intersection(target)
                return overlap.width > target.width / 2 && web.scrollView.alpha > 0.99 && !web.isLoading
            }
            return content.subviews.contains { loaded(in: $0) }
        }
        return scroll.subviews.contains { loaded(in: $0) }
    }

    private func settlePageDrag(_ drag: PageDrag, target: CGPoint, velocity: CGFloat) async {
        let revision = pageTransitionRevision
        let origin = drag.scroll?.contentOffset ?? drag.origin
        let transform = pageContent?.transform ?? .identity
        let distance = abs(origin.x - target.x)
        let duration = min(0.4, max(0.16, distance / max(abs(velocity), 900)))
        let start = CACurrentMediaTime()
        // Update WebKit's actual scroll offsets on each frame so the DOM and
        // visible page agree before the settled text position is captured.
        while revision == pageTransitionRevision {
            let progress = UIAccessibility.isReduceMotionEnabled ? 1 : min(1, (CACurrentMediaTime() - start) / duration)
            let fraction = CGFloat(1 - pow(1 - progress, 3))
            UIView.performWithoutAnimation {
                drag.scroll?.setContentOffset(CGPoint(x: origin.x + (target.x - origin.x) * fraction,
                                                      y: origin.y + (target.y - origin.y) * fraction), animated: false)
                self.pageContent?.transform = CGAffineTransform(translationX: transform.tx * (1 - fraction),
                                                               y: transform.ty * (1 - fraction))
            }
            if progress >= 1 { return }
            do { try await Task.sleep(nanoseconds: 16_000_000) }
            catch { return }
        }
    }

    func cancelPageTransition() {
        pageTransitionRevision += 1
        clearPageAnimation()
        if let drag = pageDrag {
            drag.webView.scrollView.setContentOffset(drag.pageOrigin, animated: false)
            drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        }
        pageDrag = nil
        if isTurningPage { view.isUserInteractionEnabled = true }
        isTurningPage = false
    }

    private func clearPageAnimation() {
        let animator = pageAnimator
        pageAnimator = nil
        if animator?.state == .active {
            animator?.stopAnimation(false)
            animator?.finishAnimation(at: .current)
        }
        pageSnapshot?.removeFromSuperview()
        pageContent?.transform = .identity
        committedPreview = false
        pageSnapshot = nil
        pageContent = nil
    }

    private func waitForEPUBContent() async throws {
        let revision = pageTransitionRevision
        // Readium resumes navigation before unhiding a cold chapter's scroll view.
        // Observe UIKit visibility instead of guessing a rendering delay.
        for _ in 0..<120 {
            guard revision == pageTransitionRevision, view.window != nil else { throw CancellationError() }
            if children.first.map({ hasVisibleEPUBContent(in: $0.view) }) == true { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw NSError(domain: "Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: "章节内容尚未显示，请重试。"])
    }

    private func hasVisibleEPUBContent(in content: UIView) -> Bool {
        guard !content.isHidden, content.alpha > 0.99 else { return false }
        if let webView = content as? WKWebView {
            let visible = webView.convert(webView.bounds, to: view).intersection(view.bounds)
            return visible.width > view.bounds.width / 2 && visible.height > view.bounds.height / 2
                && webView.scrollView.alpha > 0.99
        }
        return content.subviews.contains { hasVisibleEPUBContent(in: $0) }
    }

    private func animatePageTurn(direction: CGFloat, navigate: () async -> Bool) async -> Bool {
        if committedPreview {
            let revision = pageTransitionRevision
            defer { if revision == pageTransitionRevision { clearPageAnimation() } }
            return await navigate()
        }
        guard !UIAccessibility.isReduceMotionEnabled,
              let content = children.first?.view ?? view.subviews.first(where: { $0 is PDFView }),
              view.window != nil, view.bounds.width > 0,
              let snapshot = content.snapshotView(afterScreenUpdates: false) else {
            return await navigate()
        }
        clearPageAnimation()
        let revision = pageTransitionRevision
        let size = view.bounds.size
        snapshot.frame = content.convert(content.bounds, to: view)
        snapshot.isUserInteractionEnabled = true
        view.addSubview(snapshot)
        pageSnapshot = snapshot
        pageContent = content
        defer {
            if revision == pageTransitionRevision { clearPageAnimation() }
            snapshot.removeFromSuperview()
        }

        // Navigation owns chapter loading and locators; animate only our views
        // once Readium has finished its non-animated navigation.
        let moved = await navigate()
        guard moved, revision == pageTransitionRevision, content.superview === view,
              view.window != nil, view.bounds.size == size else { return false }
        view.layoutIfNeeded()
        guard revision == pageTransitionRevision else { return false }
        let offset = CGAffineTransform(translationX: direction * size.width, y: 0)
        content.transform = offset
        let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1))
        let animator = UIViewPropertyAnimator(duration: 0.28, timingParameters: timing)
        pageAnimator = animator
        animator.addAnimations {
            content.transform = .identity
            snapshot.transform = offset.inverted()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animator.addCompletion { _ in continuation.resume() }
            animator.startAnimation()
        }
        return revision == pageTransitionRevision
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        transitioning = true
        onLayoutWillChange?()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.transitioning = false
            self?.onLayoutDidChange?()
        }
    }

    override func viewWillLayoutSubviews() {
        if layoutSize != view.bounds.size {
            layoutSize = view.bounds.size
            layoutChanged = true
        }
        super.viewWillLayoutSubviews()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?(view.bounds.size, traitCollection.userInterfaceIdiom)
        if layoutChanged && !transitioning { onLayoutDidChange?() }
        layoutChanged = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }
    override func viewWillDisappear(_ animated: Bool) {
        cancelPageTransition()
        appeared = false
        super.viewWillDisappear(animated)
    }
    func replaceChild(with child: UIViewController) {
        cancelPageTransition()
        registeredPans.removeAllObjects()
        for previous in children {
            previous.willMove(toParent: nil)
            if appeared { previous.beginAppearanceTransition(false, animated: false) }
            previous.view.removeFromSuperview()
            if appeared { previous.endAppearanceTransition() }
            previous.removeFromParent()
        }
        addChild(child)
        child.view.frame = view.bounds
        // UIKit forwards an in-flight parent appearance transition automatically.
        // Only start a separate transition when the parent has already appeared.
        if appeared { child.beginAppearanceTransition(true, animated: false) }
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
        view.setNeedsLayout(); view.layoutIfNeeded()
        if appeared { child.endAppearanceTransition() }
    }
}
