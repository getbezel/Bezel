import AppKit
import ApplicationServices
import Observation
import SwiftUI

/// AX uses top-left display coordinates; AppKit uses a bottom-left desktop origin.
@MainActor
enum FocusedWindowAccess {
    struct Window {
        let element: AXUIElement
        let app: NSRunningApplication
        let frame: CGRect
    }

    static var lastExternalPID: pid_t?

    static func current(preferExternal: Bool = false) -> Window? {
        guard AccessibilityAccess.canControlWindows else { return nil }
        var app = NSWorkspace.shared.frontmostApplication
        if preferExternal, app?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let pid = lastExternalPID {
            app = NSRunningApplication(processIdentifier: pid)
        }
        guard let app else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(raw, to: AXUIElement.self)
        guard let frame = frame(of: window), frame.width > 1, frame.height > 1 else { return nil }
        return Window(element: window, app: app, frame: frame)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func appKitFrame(_ axFrame: CGRect) -> CGRect {
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: axFrame.minX, y: desktopTop - axFrame.maxY, width: axFrame.width, height: axFrame.height)
    }

    static func axFrame(_ frame: CGRect) -> CGRect {
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }
}

enum GridLayout: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case topLeft, topRight, bottomLeft, bottomRight, maximize
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .leftThird: "Left third"
        case .centerThird: "Center third"
        case .rightThird: "Right third"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .maximize: "Fill screen"
        }
    }
    var rect: CGRect {
        switch self {
        case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .bottomHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .leftThird: CGRect(x: 0, y: 0, width: 1 / 3, height: 1)
        case .centerThird: CGRect(x: 1 / 3, y: 0, width: 1 / 3, height: 1)
        case .rightThird: CGRect(x: 2 / 3, y: 0, width: 1 / 3, height: 1)
        case .topLeft: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .topRight: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .bottomLeft: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .bottomRight: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .maximize: CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }
}

@MainActor @Observable
final class GridService {
    var gap: Double = 12 {
        didSet { UserDefaults.standard.set(gap, forKey: "grid.gap") }
    }
    var lastError: String?
    var lastAction: String?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init() {
        if UserDefaults.standard.object(forKey: "grid.gap") != nil {
            gap = min(48, max(0, UserDefaults.standard.double(forKey: "grid.gap")))
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            FocusedWindowAccess.lastExternalPID = app.processIdentifier
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                if pid != ProcessInfo.processInfo.processIdentifier { FocusedWindowAccess.lastExternalPID = pid }
            }
        }
    }

    func stop() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func tile(_ layout: GridLayout) { apply(layout.rect, title: layout.title) }

    func tileCustom(columns: Int, rows: Int, column: Int, row: Int) {
        guard (1...12).contains(columns), (1...12).contains(rows), (0..<columns).contains(column), (0..<rows).contains(row) else {
            lastError = "Choose a valid cell in a grid of up to 12 × 12."
            return
        }
        apply(CGRect(x: Double(column) / Double(columns), y: 1 - Double(row + 1) / Double(rows),
                     width: 1 / Double(columns), height: 1 / Double(rows)), title: "Custom grid")
    }

    private func apply(_ unit: CGRect, title: String) {
        lastError = nil
        guard AccessibilityAccess.canControlWindows else {
            lastError = "macOS is blocking window access for this copy of Bezel. If Bezel is already enabled in Accessibility settings, remove the old entry and add the app shown in Bezel Settings → Privacy → Show This App in Finder."
            return
        }
        guard let window = FocusedWindowAccess.current(preferExternal: true) else {
            lastError = "Switch to an application window first. This app may not expose a movable window."
            return
        }
        let appKitWindow = FocusedWindowAccess.appKitFrame(window.frame)
        let screen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(appKitWindow)
            let right = rhs.frame.intersection(appKitWindow)
            return left.width * left.height < right.width * right.height
        } ?? NSScreen.main
        guard let screen else { return }
        let inset = CGFloat(max(0, min(gap, 48)))
        let area = screen.visibleFrame.insetBy(dx: inset / 2, dy: inset / 2)
        let target = CGRect(x: area.minX + area.width * unit.minX + inset / 2,
                            y: area.minY + area.height * unit.minY + inset / 2,
                            width: area.width * unit.width - inset,
                            height: area.height * unit.height - inset).integral
        let ax = FocusedWindowAccess.axFrame(target)
        var point = ax.origin
        var size = ax.size
        guard let positionValue = AXValueCreate(.cgPoint, &point), let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        // Resize before and after moving; some apps constrain size to the original display.
        AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        let move = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, positionValue)
        let resize = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
        if move != .success || resize != .success {
            lastError = "This window cannot be resized or moved. Exit full screen and try again."
        } else {
            lastAction = "\(window.app.localizedName ?? "Window") · \(title)"
            window.app.activate()
            if let actual = FocusedWindowAccess.frame(of: window.element),
               abs(actual.width - ax.width) > 8 || abs(actual.height - ax.height) > 8 {
                lastError = "The app’s minimum window size prevents an exact fit."
            }
        }
    }
}

struct GridView: View {
    @Bindable var service: GridService
    @Bindable var menuManager: MenuBarManager
    @State private var columns = 3
    @State private var rows = 2
    @State private var column = 1
    @State private var row = 1

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 12) {
                    ForEach(GridLayout.allCases) { layout in
                        Button { service.tile(layout) } label: {
                            VStack(spacing: 10) {
                                GeometryReader { proxy in
                                    RoundedRectangle(cornerRadius: 5).stroke(.secondary.opacity(0.35), lineWidth: 1)
                                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.65))
                                        .frame(width: max(3, proxy.size.width * layout.rect.width - 5), height: max(3, proxy.size.height * layout.rect.height - 5))
                                        .offset(x: proxy.size.width * layout.rect.minX + 2.5, y: proxy.size.height * (1 - layout.rect.maxY) + 2.5)
                                }.frame(width: 52, height: 35)
                                Text(layout.title).font(.caption)
                            }.frame(maxWidth: .infinity).padding(8)
                        }.buttonStyle(.bordered)
                    }
                }.padding(.vertical, 8)
                LabeledContent("Window spacing", value: "\(Int(service.gap)) pt")
                Slider(value: $service.gap, in: 0...48, step: 1)
            } header: { Text("Arrange your workspace") } footer: {
                Text("Select a layout for your most recently active app. Accessibility access is required. Full-screen windows must first leave full screen.")
            }
            Section("Custom grid") {
                Stepper("Columns: \(columns)", value: $columns, in: 1...12).onChange(of: columns) { _, value in column = min(column, value) }
                Stepper("Rows: \(rows)", value: $rows, in: 1...12).onChange(of: rows) { _, value in row = min(row, value) }
                Stepper("Column: \(column)", value: $column, in: 1...columns)
                Stepper("Row: \(row)", value: $row, in: 1...rows)
                Button("Move to Cell") { service.tileCustom(columns: columns, rows: rows, column: column - 1, row: row - 1) }
            }
            Section("Menu bar") { MenuBarManagerControls(manager: menuManager) }
            if let action = service.lastAction { Section { Label(action, systemImage: "checkmark.circle").foregroundStyle(.secondary) } }
            if let error = service.lastError { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
        }.formStyle(.grouped).navigationTitle("Grid")
        .alert("Couldn’t arrange this window", isPresented: Binding(
            get: { service.lastError != nil },
            set: { if !$0 { service.lastError = nil } }
        )) {
            if !AccessibilityAccess.canControlWindows {
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button("OK", role: .cancel) { service.lastError = nil }
        } message: {
            Text(service.lastError ?? "")
        }
    }
}
