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

/// Owns the preview, animator, and native drag for one turn of the viewport.
@MainActor private final class PageTurnTransition {
    enum Phase { case active, cleaningUp, finished }

    private struct Preview {
        let snapshot: UIView
        let content: UIView
    }

    let surface: ReadiumPageTurnSurface?
    var navigationStarted = false
    private(set) var phase = Phase.active
    private var preview: Preview?
    private var animator: UIViewPropertyAnimator?

    init(surface: ReadiumPageTurnSurface?) { self.surface = surface }

    func capturePreview(of content: UIView?, in viewport: UIView) -> Bool {
        guard phase == .active, let content, let snapshot = content.snapshotView(afterScreenUpdates: false) else { return false }
        snapshot.frame = content.convert(content.bounds, to: viewport)
        snapshot.isUserInteractionEnabled = true
        guard phase == .active else { return false }
        preview = Preview(snapshot: snapshot, content: content)
        viewport.addSubview(snapshot)
        if phase != .active {
            snapshot.removeFromSuperview()
            return false
        }
        return true
    }

    func animate(in viewport: UIView, content: UIView?, direction: CGFloat, isCurrent: @MainActor () -> Bool,
                 navigate: @MainActor () async -> Bool) async -> Bool {
        defer { clearPreview() }
        if preview != nil { return await navigate() }
        guard !UIAccessibility.isReduceMotionEnabled, viewport.window != nil, viewport.bounds.width > 0,
              capturePreview(of: content, in: viewport), let preview else {
            return await navigate()
        }
        let size = viewport.bounds.size

        // Animate only the views after Readium finishes its non-animated navigation.
        let moved = await navigate()
        guard moved, isCurrent(), preview.content.superview === viewport,
              viewport.window != nil, viewport.bounds.size == size else { return false }
        viewport.layoutIfNeeded()
        guard isCurrent() else { return false }

        let offset = CGAffineTransform(translationX: direction * size.width, y: 0)
        preview.content.transform = offset
        let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1))
        let animator = UIViewPropertyAnimator(duration: 0.28, timingParameters: timing)
        self.animator = animator
        animator.addAnimations {
            preview.content.transform = .identity
            preview.snapshot.transform = offset.inverted()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animator.addCompletion { _ in continuation.resume() }
            animator.startAnimation()
        }
        return isCurrent()
    }

    func end(cancelled: Bool) {
        phase = .cleaningUp
        if !cancelled { surface?.endDrag() }
        clearPreview()
        if cancelled { surface?.cancelDrag() }
        phase = .finished
    }

    private func clearPreview() {
        let animator = animator
        let preview = preview
        self.animator = nil
        self.preview = nil
        if animator?.state == .active {
            animator?.stopAnimation(false)
            animator?.finishAnimation(at: .current)
        }
        preview?.snapshot.removeFromSuperview()
        preview?.content.transform = .identity
    }
}

@MainActor final class ReaderContainerController: UIViewController, UIGestureRecognizerDelegate {
    private var appeared = false
    private var layoutSize: CGSize = .zero
    private var layoutChanged = false
    private var transitioning = false
    private var activeTurn: PageTurnTransition?
    private var pageTurnSurface: ReadiumPageTurnSurface?
    var onLayout: ((CGSize, UIUserInterfaceIdiom) -> Void)?
    var onLayoutWillChange: (() -> Void)?
    var onLayoutDidChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?
    var onPageTurnEnded: (() -> Void)?
    weak var pageTurnDelegate: ReaderPageTurnDelegate?
    var isTurningPage: Bool {
        guard let activeTurn else { return false }
        return activeTurn.phase != .finished
    }
    var allowsContentInteraction = true {
        didSet { updateContentInteraction() }
    }
    private var finishingTurn: PageTurnTransition? {
        didSet { updateContentInteraction() }
    }
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
        if isViewLoaded { view.isUserInteractionEnabled = allowsContentInteraction && finishingTurn == nil }
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
        guard abs(translation.x) > abs(translation.y), let turn = beginTurn(isGesture: true) else { return false }
        turn.surface?.beginDrag()
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
            if let turn = activeTurn, finishingTurn !== turn { cancelPageTransition() }
        default:
            break
        }
    }

    func finishPageTurn(translation: CGPoint, velocity: CGPoint = .zero) {
        guard let turn = activeTurn, isCurrent(turn), finishingTurn !== turn else { return }
        let projected = translation.x + velocity.x * 0.12
        let crossedThreshold = abs(projected) >= max(32, view.bounds.width * 0.2)
        let quickSwipe = abs(translation.x) >= 8 && abs(velocity.x) >= 450
        let commit = translation.x * projected > 0 && (crossedThreshold || quickSwipe)
        updatePageTurn(translation: translation)
        guard isCurrent(turn) else { return }
        finishingTurn = turn
        Task { [weak self] in
            guard let self, self.isCurrent(turn) else { return }
            let completion: ReadiumPageTurnSurface.Completion
            if let surface = turn.surface {
                completion = await surface.finishDrag(commit: commit, velocity: velocity.x, isCurrent: {
                    self.isCurrent(turn)
                }, capturePreview: {
                    turn.capturePreview(of: self.children.first?.view, in: self.view)
                })
            } else {
                completion = commit ? .navigate : .complete(committed: false)
            }
            guard self.isCurrent(turn) else { return }
            switch completion {
            case .navigate:
                await self.performPageTurn(towardLeft: projected < 0, turn: turn)
            case .complete(let committed):
                await self.completePageTurn(committed ? .settled : .unchanged, turn: turn)
            }
        }
    }

    /// Buttons and gestures share the same begin, completion, and cancellation ownership.
    func turnPage(towardLeft: Bool) async {
        guard let turn = beginTurn(isGesture: false) else { return }
        await performPageTurn(towardLeft: towardLeft, turn: turn)
    }

    private func beginTurn(isGesture: Bool) -> PageTurnTransition? {
        guard activeTurn == nil, pageTurnDelegate?.canBeginPageTurn(isGesture: isGesture) == true else { return nil }
        let turn = PageTurnTransition(surface: pageTurnSurface)
        activeTurn = turn
        pageTurnDelegate?.pageTurnWillBegin()
        return isCurrent(turn) ? turn : nil
    }

    private func isCurrent(_ turn: PageTurnTransition) -> Bool {
        activeTurn === turn && turn.phase == .active
    }

    private func performPageTurn(towardLeft: Bool, turn: PageTurnTransition) async {
        guard isCurrent(turn) else { return }
        finishingTurn = turn
        var failure: Error?
        let content = children.first?.view ?? view.subviews.first(where: { $0 is PDFView })
        let moved = await turn.animate(in: view, content: content, direction: towardLeft ? 1 : -1,
            isCurrent: { self.isCurrent(turn) }) {
            do {
                guard self.isCurrent(turn) else { return false }
                turn.navigationStarted = true
                let moved = try await self.pageTurnDelegate?.movePage(towardLeft: towardLeft) == true
                guard self.isCurrent(turn) else { return false }
                if !moved {
                    turn.navigationStarted = false
                    return false
                }
                if let surface = turn.surface {
                    try await surface.waitForContent { self.isCurrent(turn) }
                }
                return self.isCurrent(turn)
            } catch is CancellationError {
                return false
            } catch {
                failure = error
                return false
            }
        }
        guard isCurrent(turn) else { return }
        let outcome: PageTurnOutcome
        if moved {
            outcome = .settled
        } else if turn.navigationStarted {
            outcome = .restoreOrigin(failure)
        } else {
            outcome = .unchanged
        }
        await completePageTurn(outcome, turn: turn)
    }

    private func completePageTurn(_ outcome: PageTurnOutcome, turn: PageTurnTransition) async {
        guard isCurrent(turn) else { return }
        // Do not unlock native pans until the settled position has been captured.
        await pageTurnDelegate?.pageTurnDidFinish(outcome)
        endTurn(turn, cancelled: false)
    }

    func updatePageTurn(translation: CGPoint) {
        guard let turn = activeTurn, isCurrent(turn) else { return }
        turn.surface?.updateDrag(translation: translation)
    }

    func cancelPageTransition() {
        guard let turn = activeTurn else { return }
        endTurn(turn, cancelled: true)
    }

    private func endTurn(_ turn: PageTurnTransition, cancelled: Bool) {
        guard isCurrent(turn) else { return }
        turn.end(cancelled: cancelled)
        // Keep the slot occupied until synchronous delegate notifications have finished.
        onPageTurnEnded?()
        if cancelled { pageTurnDelegate?.pageTurnWasCancelled(needsRestoration: turn.navigationStarted) }
        activeTurn = nil
        if finishingTurn === turn { finishingTurn = nil }
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
