import UIKit

/// All vertical coordinates refer to the outer scroll view's content.
struct ContinuousEPUBLayout {
    struct Viewport {
        let size: CGSize
        let offset: CGFloat
        let insets: UIEdgeInsets

        var readingTop: CGFloat { max(0, offset + insets.top) }
        var readingBottom: CGFloat { max(readingTop, offset + size.height - insets.bottom) }
    }

    struct ScrollPosition {
        let offset: CGFloat
        let insets: UIEdgeInsets
    }

    struct ChapterFrame {
        let clip: CGRect
        let web: CGRect
        let offset: CGFloat
    }

    // The last edge is the total content height.
    private var edges: [CGFloat]

    init(chapterCount: Int) {
        edges = (0...chapterCount).map { CGFloat($0) * 1_200 }
    }

    var chapters: Range<Int> { 0..<(edges.count - 1) }
    var contentHeight: CGFloat { edges[edges.count - 1] }

    private func chapter(at y: CGFloat) -> Int {
        var lower = 0
        var upper = chapters.upperBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if edges[middle + 1] <= y { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, min(lower, chapters.upperBound - 1))
    }

    func visibleChapter(in viewport: Viewport) -> Int { chapter(at: viewport.readingTop + 1) }

    func retainedChapters(in viewport: Viewport, target: Int?) -> ClosedRange<Int> {
        let index = target ?? visibleChapter(in: viewport)
        let top = target.map { edges[$0] } ?? viewport.readingTop
        let last = chapter(at: top + viewport.size.height * 2)
        return max(0, index - 2)...min(chapters.upperBound - 1, max(index + 2, last))
    }

    func readableRange(in index: Int, viewport: Viewport) -> ClosedRange<CGFloat> {
        let origin = edges[index]
        let height = edges[index + 1] - origin
        let top = min(height, max(0, viewport.readingTop - origin))
        let bottom = min(height, max(top, viewport.readingBottom - origin))
        return top...bottom
    }

    func progression(in index: Int, viewport: Viewport) -> Double {
        Double(readableRange(in: index, viewport: viewport).lowerBound / (edges[index + 1] - edges[index]))
    }

    func frame(for index: Int, in viewport: Viewport) -> ChapterFrame {
        let origin = edges[index]
        let height = edges[index + 1] - origin
        let offset = min(max(0, viewport.offset - origin), max(0, height - viewport.size.height))
        return ChapterFrame(
            clip: CGRect(x: 0, y: origin + offset, width: viewport.size.width, height: min(viewport.size.height, height)),
            // Keep vh independent of the measured document height.
            web: CGRect(origin: .zero, size: viewport.size),
            offset: offset)
    }

    func align(_ readingTop: CGFloat, in viewport: Viewport) -> ScrollPosition {
        let y = max(0, readingTop) - viewport.insets.top
        var insets = viewport.insets
        // A short final chapter can need extra space to align an anchor.
        insets.bottom = max(insets.bottom, y + viewport.size.height - contentHeight)
        return ScrollPosition(offset: y, insets: insets)
    }

    func align(chapter index: Int, at localY: CGFloat, in viewport: Viewport) -> ScrollPosition {
        let top = min(max(edges[index] + localY, 0), max(0, contentHeight - 1))
        return align(top, in: viewport)
    }

    mutating func measure(_ height: CGFloat, chapter index: Int, in viewport: Viewport) -> ScrollPosition? {
        guard chapters.contains(index), height.isFinite, height > 0 else { return nil }
        let delta = max(1, height) - (edges[index + 1] - edges[index])
        guard abs(delta) > 0.5 else { return nil }
        let visible = visibleChapter(in: viewport)
        let top = viewport.readingTop + (index < visible ? delta : 0)
        for next in (index + 1)..<edges.count { edges[next] += delta }
        return align(min(top, edges[visible + 1] - 1), in: viewport)
    }
}
