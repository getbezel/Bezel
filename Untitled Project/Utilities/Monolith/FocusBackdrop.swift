import AppKit
import QuartzCore

/// One continuous surface per screen. Adjacent vector rings feather outward;
/// the active window remains completely clear, including its rounded corners.
enum FocusDimmingGeometry {
    static let feather: CGFloat = 14
    static let steps = 10

    static func localWindow(_ window: CGRect, in display: CGRect) -> CGRect {
        window.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    static func opening(_ window: CGRect, expansion: CGFloat) -> CGPath {
        let rect = window.insetBy(dx: -expansion, dy: -expansion)
        let radius = min(12 + expansion, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    static func paths(bounds: CGRect, window: CGRect) -> [CGPath] {
        let exterior = CGMutablePath()
        exterior.addRect(bounds)
        exterior.addPath(opening(window, expansion: feather))
        var result: [CGPath] = [exterior]
        for step in 0..<steps {
            let ring = CGMutablePath()
            ring.addPath(opening(window, expansion: feather * CGFloat(step + 1) / CGFloat(steps)))
            ring.addPath(opening(window, expansion: feather * CGFloat(step) / CGFloat(steps)))
            result.append(ring)
        }
        return result
    }

    static func ringAlpha(_ step: Int) -> CGFloat {
        let t = (CGFloat(step) + 0.5) / CGFloat(steps)
        return t * t * (3 - 2 * t)
    }
}

@MainActor
final class FocusBackdropView: NSView {
    private let shapes: [CAShapeLayer] = (0...FocusDimmingGeometry.steps).map { _ in CAShapeLayer() }
    private var windowRect: CGRect?
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        for (index, shape) in shapes.enumerated() {
            shape.fillRule = .evenOdd
            shape.fillColor = NSColor.black.withAlphaComponent(index == 0 ? 1 : FocusDimmingGeometry.ringAlpha(index - 1)).cgColor
            shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(window: CGRect, animated: Bool, reduceMotion: Bool) {
        guard windowRect != window else { return }
        let wasVisible = windowRect != nil
        windowRect = window
        applyPaths(animated: animated && wasVisible && !reduceMotion)
    }

    override func layout() {
        super.layout()
        applyPaths(animated: false)
    }

    private func applyPaths(animated: Bool) {
        guard let windowRect else { return }
        let paths = FocusDimmingGeometry.paths(bounds: bounds, window: windowRect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (shape, path) in zip(shapes, paths) {
            let previous = shape.presentation()?.path ?? shape.path
            shape.removeAnimation(forKey: "focus")
            shape.frame = bounds
            shape.path = path
            if animated, let previous {
                let transition = CABasicAnimation(keyPath: "path")
                transition.fromValue = previous
                transition.toValue = path
                transition.duration = 0.20
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                shape.add(transition, forKey: "focus")
            }
        }
        CATransaction.commit()
    }
}
