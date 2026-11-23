import AppKit
import SwiftUI

/// Owns background moves and grip resizing before SwiftUI can discard the first click.
@MainActor
final class ShelfPanel: NSPanel {
    enum Interaction { case move, content, resize }

    var onResizeFinished: (() -> Void)?
    var isResizingFromGrip: Bool { resizeSession != nil }
    private let regions = NSHashTable<ShelfMouseRegionView>.weakObjects()
    private var resizeSession: ShelfResizeSession?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    fileprivate func register(_ view: ShelfMouseRegionView) { regions.add(view) }
    fileprivate func unregister(_ view: ShelfMouseRegionView) { regions.remove(view) }

    func interaction(at point: NSPoint) -> Interaction {
        guard let contentView, contentView.bounds.contains(contentView.convert(point, from: nil)) else { return .content }
        let hits = regions.allObjects.filter { view in
            let area = view.visibleRect.intersection(view.bounds)
            return view.window === self && !view.isHiddenOrHasHiddenAncestor &&
                !area.isEmpty && view.convert(area, to: nil).contains(point)
        }
        if hits.contains(where: { $0.interaction == .resize }) { return .resize }
        if !hits.isEmpty { return .content }
        // Native controls, including scroll bars, always keep their own mouse handling.
        var hit = contentView.hitTest(contentView.convert(point, from: nil))
        while let view = hit {
            if view is NSControl { return .content }
            hit = view.superview
        }
        return .move
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) {
            switch interaction(at: event.locationInWindow) {
            case .move:
                performDrag(with: event)
                return
            case .resize:
                guard let screen else { return }
                resizeSession = ShelfResizeSession(frame: frame,
                                                  pointer: convertPoint(toScreen: event.locationInWindow),
                                                  visibleFrame: screen.visibleFrame.insetBy(dx: 8, dy: 8))
                return
            case .content: break
            }
        }
        if let resizeSession, event.type == .leftMouseDragged || event.type == .leftMouseUp {
            // Screen coordinates remain stable when the panel's bottom edge moves.
            let point = convertPoint(toScreen: event.locationInWindow)
            setFrame(resizeSession.frame(at: point), display: true)
            if event.type == .leftMouseUp { finishResize() }
            return
        }
        super.sendEvent(event)
    }

    override func orderOut(_ sender: Any?) {
        finishResize()
        super.orderOut(sender)
    }

    private func finishResize() {
        guard resizeSession != nil else { return }
        resizeSession = nil
        onResizeFinished?()
    }
}

struct ShelfResizeSession {
    let frame: CGRect
    let pointer: CGPoint
    let visibleFrame: CGRect

    func frame(at point: CGPoint) -> CGRect {
        let start = ShelfPlacement.constrained(frame, to: visibleFrame)
        let maxWidth = min(640, visibleFrame.maxX - start.minX)
        let maxHeight = min(720, start.maxY - visibleFrame.minY)
        let width = min(max(start.width + point.x - pointer.x, min(280, maxWidth)), maxWidth)
        let height = min(max(start.height + pointer.y - point.y, min(240, maxHeight)), maxHeight)
        return CGRect(x: start.minX, y: start.maxY - height, width: width, height: height)
    }
}

/// Marks live SwiftUI control/asset bounds without taking over their events.
struct ShelfMouseRegion: NSViewRepresentable {
    var interaction: ShelfPanel.Interaction = .content

    func makeNSView(context: Context) -> ShelfMouseRegionView { ShelfMouseRegionView(interaction: interaction) }
    func updateNSView(_ view: ShelfMouseRegionView, context: Context) {}
}

@MainActor
final class ShelfMouseRegionView: NSView {
    let interaction: ShelfPanel.Interaction
    private weak var registeredPanel: ShelfPanel?

    init(interaction: ShelfPanel.Interaction) {
        self.interaction = interaction
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registeredPanel?.unregister(self)
        registeredPanel = window as? ShelfPanel
        registeredPanel?.register(self)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func resetCursorRects() {
        if interaction == .resize {
            addCursorRect(visibleRect.intersection(bounds), cursor: .frameResize(position: .bottomRight, directions: .all))
        }
    }
}

extension View {
    /// Attach to the entire drawer so the footer padding between the arrow and window edge also resizes.
    func shelfResizeCorner() -> some View {
        overlay(alignment: .bottomTrailing) {
            ShelfMouseRegion(interaction: .resize).frame(width: 46, height: 46)
                .accessibilityHidden(true)
        }
    }

    func shelfMouseRegion(_ interaction: ShelfPanel.Interaction = .content) -> some View {
        background(ShelfMouseRegion(interaction: interaction))
    }
}
