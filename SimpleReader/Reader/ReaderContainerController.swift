import UIKit
import PDFKit

enum PageTurnOutcome {
    case settled
    case unchanged
    case restoreOrigin(Error?)
}

@MainActor protocol ReaderPageTurnDelegate: AnyObject {
    func canBeginPageTurn(isGesture: Bool) -> Bool
    func pageTurnWillBegin()
    func movePage(towardLeft: Bool) async throws -> Bool
    func pageTurnDidFinish(_ outcome: PageTurnOutcome) async
    func pageTurnWasCancelled(needsRestoration: Bool)
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
    private var pageTurnSurface: ReadiumPageTurnSurface?
    var onLayout: ((CGSize, UIUserInterfaceIdiom) -> Void)?
    var onLayoutWillChange: (() -> Void)?
    var onLayoutDidChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    weak var pageTurnDelegate: ReaderPageTurnDelegate?
    private(set) var isTurningPage = false
    var allowsContentInteraction = true {
        didSet { updateContentInteraction() }
    }
    private var finishingPageTurn = false {
        didSet { updateContentInteraction() }
    }
    private var pageNavigationStarted = false
    private lazy var pageTurnPan = UIPanGestureRecognizer(target: self, action: #selector(handlePageTurn(_:)))

    override func loadView() {
        let surface = ReaderContainerView()
        surface.onSizeWillChange = { [weak self] in
            self?.layoutChanged = true
            self?.onLayoutWillChange?()
        }
        view = surface
        updateContentInteraction()
    }

    private func updateContentInteraction() {
        if isViewLoaded { view.isUserInteractionEnabled = allowsContentInteraction && !finishingPageTurn }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: ReaderContainerController, _: UITraitCollection) in
            controller.onAppearanceChange?()
        }
        pageTurnPan.maximumNumberOfTouches = 1
        pageTurnPan.delegate = self
        view.addGestureRecognizer(pageTurnPan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pageTurnPan && beginPageTurn(translation: pageTurnPan.translation(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pageTurnPan, pageTurnDelegate?.canBeginPageTurn(isGesture: true) == true else { return false }
        pageTurnSurface?.registerNativePans(requiringToFail: pageTurnPan)
        return true
    }

    func beginPageTurn(translation: CGPoint) -> Bool {
        guard abs(translation.x) > abs(translation.y), beginTurn(isGesture: true) else { return false }
        pageTurnSurface?.beginDrag()
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
            if isTurningPage && !finishingPageTurn { cancelPageTransition() }
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
        finishingPageTurn = true
        let revision = pageTransitionRevision
        let surface = pageTurnSurface
        Task { [weak self] in
            guard let self, revision == self.pageTransitionRevision else { return }
            let completion: ReadiumPageTurnSurface.Completion
            if let surface {
                completion = await surface.finishDrag(commit: commit, velocity: velocity.x, isCurrent: {
                    revision == self.pageTransitionRevision && self.pageTurnSurface === surface
                }, capturePreview: {
                    self.captureCommittedPreview()
                })
            } else {
                completion = commit ? .navigate : .complete(committed: false)
            }
            guard revision == self.pageTransitionRevision else { return }
            switch completion {
            case .navigate:
                await self.performPageTurn(towardLeft: projected < 0, revision: revision)
            case .complete(let committed):
                await self.completePageTurn(committed ? .settled : .unchanged, revision: revision)
            }
        }
    }

    private func captureCommittedPreview() -> Bool {
        guard let content = children.first?.view,
              let snapshot = content.snapshotView(afterScreenUpdates: false) else { return false }
        snapshot.frame = content.convert(content.bounds, to: view)
        snapshot.isUserInteractionEnabled = true
        view.addSubview(snapshot)
        pageSnapshot = snapshot
        pageContent = content
        committedPreview = true
        return true
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
        finishingPageTurn = true
        var failure: Error?
        let moved = await animatePageTurn(direction: towardLeft ? 1 : -1) {
            do {
                guard revision == self.pageTransitionRevision else { return false }
                self.pageNavigationStarted = true
                let moved = try await self.pageTurnDelegate?.movePage(towardLeft: towardLeft) == true
                guard revision == self.pageTransitionRevision else { return false }
                if !moved {
                    self.pageNavigationStarted = false
                    return false
                }
                if let surface = self.pageTurnSurface {
                    try await surface.waitForContent {
                        revision == self.pageTransitionRevision && self.pageTurnSurface === surface
                    }
                }
                return revision == self.pageTransitionRevision
            } catch is CancellationError {
                return false
            } catch {
                failure = error
                return false
            }
        }
        let outcome: PageTurnOutcome
        if moved {
            outcome = .settled
        } else if pageNavigationStarted {
            outcome = .restoreOrigin(failure)
        } else {
            outcome = .unchanged
        }
        await completePageTurn(outcome, revision: revision)
    }

    private func completePageTurn(_ outcome: PageTurnOutcome, revision: Int) async {
        guard revision == pageTransitionRevision else { return }
        // Do not unlock native pans until the settled position has been captured.
        await pageTurnDelegate?.pageTurnDidFinish(outcome)
        guard revision == pageTransitionRevision else { return }
        pageTurnSurface?.endDrag()
        clearPageAnimation()
        pageNavigationStarted = false
        isTurningPage = false
        finishingPageTurn = false
    }

    func updatePageTurn(translation: CGPoint) {
        pageTurnSurface?.updateDrag(translation: translation)
    }

    func cancelPageTransition() {
        let wasTurning = isTurningPage
        let needsRestoration = pageNavigationStarted
        pageTransitionRevision += 1
        clearPageAnimation()
        pageTurnSurface?.cancelDrag()
        pageNavigationStarted = false
        isTurningPage = false
        if wasTurning { pageTurnDelegate?.pageTurnWasCancelled(needsRestoration: needsRestoration) }
        finishingPageTurn = false
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
        onVisibilityChanged?(true)
    }
    override func viewWillDisappear(_ animated: Bool) {
        appeared = false
        onVisibilityChanged?(false)
        cancelPageTransition()
        super.viewWillDisappear(animated)
    }
    func replaceChild(with child: UIViewController, pageTurnSurface: ReadiumPageTurnSurface? = nil) {
        cancelPageTransition()
        self.pageTurnSurface = pageTurnSurface
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
