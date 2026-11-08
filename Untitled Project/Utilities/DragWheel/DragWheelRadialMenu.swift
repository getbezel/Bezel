// Adapted from the user-provided DragWheel source archive (revision 9fc8867).
import AppKit

struct DWMenuItem: Sendable {
    let format: String
    let enabled: Bool
    let note: String?
}

/// Floating, non-activating panel that shows the wheel around the cursor and
/// acts as a drop target. Dropping on it means Finder never moves the file.
@MainActor final class DWRadialMenuController {
    private let panel: NSPanel
    private let wheel: DWRadialView
    private var files: [URL] = []
    private var generation = 0

    var onChoose: ((String, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    var isVisible: Bool { panel.isVisible }

    init() {
        let side = DWRadialView.outerRadius * 2 + 40
        let size = NSSize(width: side, height: side)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let d = DWRadialView.outerRadius * 2
        let blurFrame = NSRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d)
        let blur = NSVisualEffectView(frame: blurFrame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = NSImage(size: blurFrame.size, flipped: false) { rect in
            NSBezierPath(ovalIn: rect).fill(); return true
        }
        container.addSubview(blur)

        wheel = DWRadialView(frame: container.bounds)
        wheel.autoresizingMask = [.width, .height]
        container.addSubview(wheel)
        panel.contentView = container

        wheel.onChoose = { [weak self] index in
            guard let self else { return }
            guard self.wheel.items.indices.contains(index) else { return }
            let format = self.wheel.items[index].format
            let files = self.files
            self.hide()
            self.onChoose?(format, files)
        }
        wheel.onCancel = { [weak self] in
            self?.hide()
            self?.onCancel?()
        }
    }

    func show(at point: NSPoint, files: [URL], items: [DWMenuItem], sourceLabel: String) {
        generation += 1
        self.files = files
        wheel.expectedFiles = files
        wheel.items = items
        wheel.sourceLabel = sourceLabel
        wheel.hovered = nil
        wheel.needsDisplay = true

        var frame = panel.frame
        frame.origin = NSPoint(x: point.x - frame.width / 2, y: point.y - frame.height / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, v.minX), v.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, v.minY), v.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            self.panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Called after the mouse is released; gives a drop on the wheel time to land first.
    func hideAfterDrop() {
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.hide()
        }
    }
}

final class DWRadialView: NSView {
    static let outerRadius: CGFloat = 150
    static let innerRadius: CGFloat = 52

    enum Region: Equatable { case cancel, item(Int), outside }

    var items: [DWMenuItem] = []
    var sourceLabel = ""
    var hovered: Region? { didSet { if hovered != oldValue { needsDisplay = true } } }
    var expectedFiles: [URL] = []
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private var centerPoint: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    func region(at p: NSPoint) -> Region {
        let dx = p.x - centerPoint.x, dy = p.y - centerPoint.y
        let dist = hypot(dx, dy)
        if dist <= Self.innerRadius { return .cancel }
        if dist > Self.outerRadius || items.isEmpty { return .outside }
        var angle = atan2(dx, dy)               // 0 = straight up, clockwise
        if angle < 0 { angle += 2 * .pi }
        let index = Int(angle / (2 * .pi / CGFloat(items.count))) % items.count
        return .item(index)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = centerPoint
        let outer = Self.outerRadius - 4
        let inner = Self.innerRadius + 6
        let n = items.count

        if n > 0 {
            let step = 360.0 / CGFloat(n)
            for i in 0..<n {
                let a0 = CGFloat(i) * step, a1 = a0 + step     // degrees clockwise from top
                let item = items[i]

                if hovered == .item(i) {
                    let wedge = NSBezierPath()
                    wedge.appendArc(withCenter: c, radius: outer, startAngle: 90 - a0, endAngle: 90 - a1, clockwise: true)
                    wedge.appendArc(withCenter: c, radius: inner, startAngle: 90 - a1, endAngle: 90 - a0, clockwise: false)
                    wedge.close()
                    (item.enabled ? NSColor.controlAccentColor : NSColor.systemGray).withAlphaComponent(0.85).setFill()
                    wedge.fill()
                }

                if n > 1 {
                    let r = a0 * .pi / 180
                    let sep = NSBezierPath()
                    sep.move(to: NSPoint(x: c.x + inner * sin(r), y: c.y + inner * cos(r)))
                    sep.line(to: NSPoint(x: c.x + outer * sin(r), y: c.y + outer * cos(r)))
                    sep.lineWidth = 1
                    NSColor.white.withAlphaComponent(0.12).setStroke()
                    sep.stroke()
                }

                let mid = (a0 + step / 2) * .pi / 180
                let lr = (outer + inner) / 2
                let p = NSPoint(x: c.x + lr * sin(mid), y: c.y + lr * cos(mid))
                let alpha: CGFloat = item.enabled ? 1 : 0.35
                let font = NSFont.systemFont(ofSize: n > 7 ? 12.5 : 14, weight: .semibold)
                drawCentered(item.format.uppercased(), at: item.note == nil ? p : NSPoint(x: p.x, y: p.y + 6),
                             font: font, color: NSColor.white.withAlphaComponent(alpha))
                if let note = item.note {
                    drawCentered(note, at: NSPoint(x: p.x, y: p.y - 9),
                                 font: .systemFont(ofSize: 8.5), color: NSColor.white.withAlphaComponent(0.5))
                }
            }
        }

        // Cancel hub
        let r = Self.innerRadius
        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        (hovered == .cancel ? NSColor.systemRed.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.08)).setFill()
        hub.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        hub.lineWidth = 1
        hub.stroke()

        drawCentered(sourceLabel.uppercased(), at: NSPoint(x: c.x, y: c.y + 24),
                     font: .systemFont(ofSize: 9.5, weight: .medium), color: NSColor.white.withAlphaComponent(0.55))
        if case .item(let i)? = hovered, items.indices.contains(i), items[i].enabled {
            drawCentered("→ " + items[i].format.uppercased(), at: NSPoint(x: c.x, y: c.y + 1),
                         font: .systemFont(ofSize: 15, weight: .bold), color: .white)
            drawCentered("release to convert", at: NSPoint(x: c.x, y: c.y - 19),
                         font: .systemFont(ofSize: 8.5), color: NSColor.white.withAlphaComponent(0.6))
        } else {
            drawCentered("✕", at: NSPoint(x: c.x, y: c.y + 2), font: .systemFont(ofSize: 20, weight: .semibold), color: .white)
            drawCentered("cancel", at: NSPoint(x: c.x, y: c.y - 19),
                         font: .systemFont(ofSize: 10, weight: .medium), color: NSColor.white.withAlphaComponent(0.7))
        }
    }

    private func drawCentered(_ s: String, at p: NSPoint, font: NSFont, color: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = s as NSString
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
    }

    // MARK: Drop target

    override func mouseUp(with event: NSEvent) {
        switch region(at: convert(event.locationInWindow, from: nil)) {
        case .cancel: onCancel?()
        case .item(let index) where items.indices.contains(index) && items[index].enabled: onChoose?(index)
        default: break
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let reg = region(at: convert(sender.draggingLocation, from: nil))
        hovered = (reg == .outside) ? nil : reg
        switch reg {
        case .outside: return []
        case .cancel: return .copy           // swallow the drop so the original stays put
        case .item(let i): return items[i].enabled ? .copy : []
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard Set(dropped.map(\.standardizedFileURL)) == Set(expectedFiles.map(\.standardizedFileURL)) else { return false }
        let reg = region(at: convert(sender.draggingLocation, from: nil))
        hovered = nil
        switch reg {
        case .cancel:
            DispatchQueue.main.async { self.onCancel?() }
            return true
        case .item(let i) where items[i].enabled:
            DispatchQueue.main.async { self.onChoose?(i) }
            return true
        default:
            return false
        }
    }
}
