import UIKit

@MainActor final class PageCurlView: UIView {
    private struct Strip {
        let image = CALayer()
        let shade = CALayer()
    }

    private let flat = CALayer()
    private let shadow = CAGradientLayer()
    private let strips = (0..<24).map { _ in Strip() }
    private let paper: CGColor
    private let edgeTint: UIColor
    private let isDarkPaper: Bool
    private(set) var progress: CGFloat = 0

    static func capture(_ content: UIView, in viewport: UIView) -> PageCurlView? {
        let frame = content.convert(content.bounds, to: viewport)
        guard viewport.window != nil, frame.width > 0, frame.height > 0 else { return nil }
        let paper = content.backgroundColor ?? UIColor.systemBackground
        let format = UIGraphicsImageRendererFormat()
        format.scale = viewport.traitCollection.displayScale
        format.opaque = true
        var captured = false
        let image = UIGraphicsImageRenderer(size: frame.size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: frame.size)
            context.cgContext.setFillColor(paper.resolvedColor(with: content.traitCollection).cgColor)
            context.cgContext.fill(rect)
            captured = content.drawHierarchy(in: rect, afterScreenUpdates: false)
        }
        guard captured, let bitmap = image.cgImage else { return nil }
        let curl = PageCurlView(frame: frame, bitmap: bitmap, paper: paper.resolvedColor(with: content.traitCollection))
        viewport.addSubview(curl)
        return curl
    }

    private init(frame: CGRect, bitmap: CGImage, paper: UIColor) {
        self.paper = paper.cgColor
        var brightness: CGFloat = 1
        paper.getWhite(&brightness, alpha: nil)
        isDarkPaper = brightness < 0.5
        edgeTint = isDarkPaper ? .white : .black
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        shadow.colors = [edgeTint.withAlphaComponent(isDarkPaper ? 0.16 : 0.25).cgColor, UIColor.clear.cgColor]
        layer.addSublayer(shadow)
        flat.contents = bitmap
        layer.addSublayer(flat)
        for strip in strips {
            strip.image.contents = bitmap
            strip.image.addSublayer(strip.shade)
            layer.addSublayer(strip.image)
        }
        show(0, towardLeft: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ progress: CGFloat, towardLeft: Bool) {
        self.progress = min(max(progress, 0), 1)
        let width = bounds.width
        let height = bounds.height
        let pulled = width * self.progress
        let crease = width - pulled
        let radius = min(pulled * 0.52, width * 0.15, crease * 0.32)
        let bending = radius > 0.5
        let stripWidth = pulled / CGFloat(strips.count)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isHidden = self.progress >= 1
        flat.frame = CGRect(x: towardLeft ? 0 : pulled, y: 0, width: crease, height: height)
        flat.contentsRect = CGRect(x: flat.frame.minX / width, y: 0, width: crease / width, height: 1)
        shadow.isHidden = !bending
        let shadowWidth = min(radius * 1.5, pulled)
        shadow.frame = CGRect(x: towardLeft ? crease : pulled - shadowWidth, y: 0, width: shadowWidth, height: height)
        shadow.startPoint = CGPoint(x: towardLeft ? 0 : 1, y: 0.5)
        shadow.endPoint = CGPoint(x: towardLeft ? 1 : 0, y: 0.5)

        // Project the paper around a cylinder. Past the half turn the back lies flat above the front.
        for (index, strip) in strips.enumerated() {
            strip.image.isHidden = !bending
            guard bending else { continue }
            let distance = (CGFloat(index) + 0.5) * stripWidth
            let angle = min(distance / radius, .pi)
            let x = crease + radius * sin(angle) - max(0, distance - radius * .pi)
            let depth = radius * (1 - cos(angle))
            let sourceX = crease + distance - stripWidth / 2
            let stripHeight = height / (1 + depth / (width * 8))
            strip.image.bounds = CGRect(x: 0, y: 0, width: stripWidth + 0.5, height: stripHeight)
            strip.image.position = CGPoint(x: towardLeft ? x : width - x, y: height / 2)
            strip.image.contentsRect = CGRect(x: (towardLeft ? sourceX : width - sourceX - stripWidth) / width,
                y: 0, width: stripWidth / width, height: 1)
            strip.image.zPosition = depth + CGFloat(index) * 0.001
            strip.image.transform = CATransform3DMakeRotation(towardLeft ? -angle : angle, 0, 1, 0)
            strip.shade.frame = strip.image.bounds
            let light = abs(cos(angle))
            if angle > .pi / 2 {
                strip.shade.backgroundColor = paper
                strip.shade.opacity = Float(0.7 + 0.16 * light)
            } else {
                strip.shade.backgroundColor = edgeTint.cgColor
                strip.shade.opacity = Float((1 - light) * (isDarkPaper ? 0.18 : 0.28))
            }
        }
        CATransaction.commit()
    }
}
