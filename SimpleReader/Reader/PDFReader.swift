import PDFKit
import UIKit

@MainActor final class PDFReader: NSObject {
    struct Checkpoint {
        let page: Int
        let point: CGPoint
    }
    enum Target { case page(Int), checkpoint(Checkpoint) }

    private let view: PDFView
    private let document: PDFDocument
    private var controlsTap: PDFControlsTap?
    private var pageObserver: NSObjectProtocol?
    private weak var observedScrollView: UIScrollView?
    private var insets: UIEdgeInsets?
    private var twoPages: Bool
    private var isApplyingPosition = false
    private var unsettledMoves = 0
    private var isReady = false
    var onMovementBegan: (() -> Void)?
    var onPageChanged: ((ReadingPosition) -> Void)?

    init(url: URL, in container: UIView, twoPages: Bool, insets: UIEdgeInsets?,
         onTap: @escaping (CGPoint, CGRect) -> Void) throws {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw AppFailure("Couldn’t open the PDF.")
        }
        self.document = document
        self.twoPages = twoPages
        self.insets = insets
        view = PDFView(frame: container.bounds)
        super.init()
        view.document = document
        view.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        view.displaysAsBook = false
        view.autoScales = true
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        controlsTap = PDFControlsTap(view: view) { [weak view] point in
            if let view = view { onTap(point, view.bounds) }
        }
        pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        }
    }

    deinit {
        if let observer = pageObserver { NotificationCenter.default.removeObserver(observer) }
    }

    var pageCount: Int { document.pageCount }
    var isScrolling: Bool {
        guard let scroll = observedScrollView else { return false }
        return scroll.isDragging || scroll.isDecelerating
    }
    var page: Int? {
        guard let current = view.currentPage else { return nil }
        let index = document.index(for: current)
        return (0..<pageCount).contains(index) ? index : nil
    }

    var contents: [ContentsItem] {
        func flatten(_ outline: PDFOutline, depth: Int = 0) -> [ContentsItem] {
            (0..<outline.numberOfChildren).flatMap { index -> [ContentsItem] in
                guard let child = outline.child(at: index) else { return [] }
                let page = child.destination?.page.map { document.index(for: $0) }
                return [ContentsItem(title: String(repeating: "  ", count: depth) +
                    (child.label ?? String(localized: "Chapter")), link: nil, pdfPage: page)] +
                    flatten(child, depth: depth + 1)
            }
        }
        let outline = document.outlineRoot.map { flatten($0) } ?? []
        if !outline.isEmpty { return outline }
        return (0..<pageCount).map { ContentsItem(title: String(localized: "Page \($0 + 1)"), link: nil, pdfPage: $0) }
    }

    func position(updatedAt: Date = Date()) -> ReadingPosition? {
        page.map { ReadingPosition(progression: Double($0 + 1) / Double(pageCount), pdfPage: $0, updatedAt: updatedAt) }
    }

    func open(at index: Int?, updatedAt: Date) async throws -> ReadingPosition {
        // PDFKit ignores page navigation before the reader has a viewport.
        for _ in 0..<50 {
            try Task.checkCancellation()
            if view.window != nil && !view.bounds.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard view.window != nil, !view.bounds.isEmpty else {
            throw AppFailure("The PDF layout isn’t ready. Reopen the book.")
        }
        view.superview?.layoutIfNeeded()
        view.layoutIfNeeded()
        updateScrollInsets(insets)
        if let index = index { try go(to: min(max(index, 0), pageCount - 1)) }
        guard let position = position(updatedAt: updatedAt) else {
            throw AppFailure("Couldn’t restore the PDF reading position.")
        }
        isReady = true
        return position
    }

    func updateLayout(twoPages: Bool) {
        if self.twoPages != twoPages {
            self.twoPages = twoPages
            let current = view.currentPage
            applyingPosition {
                view.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
                view.autoScales = true
                updateScrollInsets(insets)
                if let current = current { alignTop(of: current) }
            }
        } else {
            updateScrollInsets(insets)
        }
    }

    func updateScrollInsets(_ insets: UIEdgeInsets?) {
        self.insets = insets
        guard let scroll = scrollView else { return }
        if observedScrollView !== scroll {
            observedScrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
            scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
            observedScrollView = scroll
        }
        guard let insets = insets else { return }
        var contentInset = scroll.contentInset
        contentInset.top = insets.top
        contentInset.bottom = insets.bottom
        guard scroll.contentInset != contentInset || scroll.contentInsetAdjustmentBehavior != .never else { return }
        let top = scroll.contentOffset.y + scroll.adjustedContentInset.top
        applyingPosition {
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.automaticallyAdjustsScrollIndicatorInsets = false
            scroll.contentInset = contentInset
            scroll.verticalScrollIndicatorInsets = insets
            setOffset(top - insets.top, in: scroll)
        }
    }

    func checkpoint(at index: Int?) -> Checkpoint? {
        guard let index = index ?? page, let page = document.page(at: index) else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        // Capture the visible top; PDFKit can report a destination near the lower edge.
        let top = view.bounds.minY + (insets?.top ?? 0)
        var point = view.convert(CGPoint(x: view.bounds.minX, y: top), to: page)
        point.x = min(max(point.x, bounds.minX), bounds.maxX)
        point.y = min(max(point.y, bounds.minY), bounds.maxY)
        return Checkpoint(page: index, point: point)
    }

    func move(to target: Target) async throws -> ReadingPosition {
        unsettledMoves += 1
        defer { unsettledMoves -= 1 }
        switch target {
        case .page(let index): try go(to: index)
        case .checkpoint(let checkpoint): try restore(checkpoint)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        guard let position = position() else { throw AppFailure("Couldn’t restore the PDF reading position.") }
        return position
    }

    private func restore(_ checkpoint: Checkpoint) throws {
        guard let page = document.page(at: checkpoint.page) else {
            throw AppFailure("Couldn’t return to the previous position.")
        }
        applyingPosition {
            view.layoutIfNeeded()
            view.go(to: PDFDestination(page: page, at: checkpoint.point))
            align(checkpoint.point, on: page)
        }
    }

    private func go(to index: Int) throws {
        guard let page = document.page(at: index) else {
            throw AppFailure("Page number outside this book’s range.")
        }
        applyingPosition { alignTop(of: page) }
    }

    func turn(forward: Bool) throws -> Bool {
        guard let page = page else { return false }
        // Without a cover, spreads start at zero-based pages 0, 2, 4.
        let start = twoPages ? page / 2 * 2 : page
        let step = twoPages ? 2 : 1
        let index = start + (forward ? step : -step)
        guard (0..<pageCount).contains(index) else { return false }
        try go(to: index)
        return true
    }

    private var scrollView: UIScrollView? {
        var ancestor = view.documentView?.superview
        while let candidate = ancestor, candidate !== view {
            if let scroll = candidate as? UIScrollView { return scroll }
            ancestor = candidate.superview
        }
        return nil
    }

    private func alignTop(of page: PDFPage) {
        view.go(to: page)
        view.layoutIfNeeded()
        let top = view.convert(page.bounds(for: view.displayBox), from: page).minY
        alignViewport(to: top)
    }

    private func align(_ point: CGPoint, on page: PDFPage) {
        view.layoutIfNeeded()
        alignViewport(to: view.convert(point, from: page).y)
    }

    private func alignViewport(to y: CGFloat) {
        guard let scroll = scrollView else { return }
        let top = view.bounds.minY + scroll.adjustedContentInset.top
        setOffset(scroll.contentOffset.y + y - top, in: scroll)
    }

    private func setOffset(_ y: CGFloat, in scroll: UIScrollView) {
        let inset = scroll.adjustedContentInset
        let bottom = scroll.contentSize.height - scroll.bounds.height + inset.bottom
        let offset = max(-inset.top, min(y, bottom))
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
    }

    private func applyingPosition(_ update: () -> Void) {
        let previous = isApplyingPosition
        isApplyingPosition = true
        defer { isApplyingPosition = previous }
        update()
    }

    private func pageChanged() {
        guard isReady, !isApplyingPosition, unsettledMoves == 0, let position = position() else { return }
        onPageChanged?(position)
    }

    @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
        if isReady, gesture.state == .began { onMovementBegan?() }
    }
}

@MainActor private final class PDFControlsTap: NSObject, UIGestureRecognizerDelegate {
    private weak var pdf: PDFView?
    private let onTap: (CGPoint) -> Void
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    init(view: PDFView, onTap: @escaping (CGPoint) -> Void) {
        pdf = view
        self.onTap = onTap
        super.init()
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let pdf = pdf, pdf.currentSelection == nil else { return }
        onTap(gesture.location(in: pdf))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let pdf = pdf, pdf.currentSelection == nil else { return false }
        let point = touch.location(in: pdf)
        guard point.x >= pdf.bounds.width * 0.2, point.x <= pdf.bounds.width * 0.8 else { return false }
        if let page = pdf.page(for: point, nearest: false), let annotation = page.annotation(at: pdf.convert(point, to: page)),
           annotation.type == PDFAnnotationSubtype.link.rawValue || annotation.type == PDFAnnotationSubtype.widget.rawValue { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let other = otherGestureRecognizer as? UITapGestureRecognizer, other.numberOfTapsRequired > 1,
              let pdf = pdf, other.view?.isDescendant(of: pdf) == true else { return false }
        return true
    }
}
