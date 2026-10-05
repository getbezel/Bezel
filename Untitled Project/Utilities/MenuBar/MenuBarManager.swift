import AppKit
import ApplicationServices
import Observation
import SwiftUI

@MainActor @Observable
final class MenuBarManager: NSObject {
    var isEnabled = UserDefaults.standard.bool(forKey: "menu.manager") {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "menu.manager"); isEnabled ? start() : stop() }
    }
    private(set) var isCollapsed = false
    private(set) var isBusy = false
    private(set) var apps: [MenuBarApp] = []
    private(set) var lastError: String?
    private(set) var hiddenBundles = Set(UserDefaults.standard.stringArray(forKey: "menu.hidden") ?? [])
    @ObservationIgnored private var toggleItem: NSStatusItem?
    @ObservationIgnored private var separator: NSStatusItem?
    @ObservationIgnored private var restriction: NSObject?
    @ObservationIgnored private var pendingRestriction: NSObject?
    @ObservationIgnored private var popover: NSPopover?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inventoryTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var permissionTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    private var usesNativeVisibility: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    func start() {
        guard isEnabled, toggleItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Bezel.MenuCollapse"
        item.button?.target = self
        item.button?.action = #selector(pressed(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel("Bezel menu bar manager")
        toggleItem = item
        if !usesNativeVisibility {
            let boundary = NSStatusBar.system.statusItem(withLength: 18)
            boundary.autosaveName = "Bezel.MenuBoundary"
            boundary.button?.title = "│"
            boundary.button?.toolTip = "Command-drag icons to the left of this divider to collapse them."
            separator = boundary
        }
        updateButton()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isEnabled else { return }
                    if self.isCollapsed && self.usesNativeVisibility { self.applyNativeRestriction() }
                }
            })
        }
        refresh()
    }

    func stop() {
        expand()
        inventoryTask?.cancel()
        inventoryTask = nil
        openTask?.cancel()
        openTask = nil
        isBusy = false
        popover?.close()
        popover = nil
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        if let separator { NSStatusBar.system.removeStatusItem(separator) }
        toggleItem = nil
        separator = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            lastError = "Enable Accessibility in Bezel’s Privacy settings to read and open other apps’ menu icons."
            return
        }
        inventoryTask?.cancel()
        let own = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> MenuBarApp? in
            guard let id = app.bundleIdentifier, id != own, !id.hasPrefix("com.apple."), app.bundleURL?.pathExtension == "app" else { return nil }
            return MenuBarApp(id: id, name: app.localizedName ?? id, pid: app.processIdentifier, extras: [])
        }
        inventoryTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { MenuBarInventory.snapshot(apps: candidates) }.value
            guard let self, !Task.isCancelled else { return }
            apps = result
            lastError = nil
            inventoryTask = nil
        }
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        guard !id.hasPrefix("com.apple."), id != Bundle.main.bundleIdentifier else { return }
        if hidden { hiddenBundles.insert(id) } else { hiddenBundles.remove(id) }
        UserDefaults.standard.set(hiddenBundles.sorted(), forKey: "menu.hidden")
        if isCollapsed && usesNativeVisibility { applyNativeRestriction() }
    }

    func toggle() {
        if isCollapsed || isBusy { expand() } else { collapse() }
    }

    func collapse() {
        guard isEnabled, toggleItem != nil else { return }
        lastError = nil
        if usesNativeVisibility {
            guard AXIsProcessTrusted() else { refresh(); return }
            guard !hiddenBundles.isEmpty else { showShelf(); return }
            applyNativeRestriction()
        } else {
            guard let separator, let boundary = separator.button?.window?.frame,
                  let arrow = toggleItem?.button?.window?.frame, boundary.midX < arrow.midX else {
                lastError = "Command-drag the divider to the left of Bezel’s chevron first."
                return
            }
            separator.length = min(10_000, max(500, (NSScreen.screens.map(\.frame.width).max() ?? 1728) * 2))
            isCollapsed = true
            updateButton()
        }
    }

    func expand() {
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        if let pendingRestriction { BezelMenuVisibilityRelease(pendingRestriction) }
        pendingRestriction = nil
        if let restriction { BezelMenuVisibilityRelease(restriction) }
        restriction = nil
        separator?.length = 18
        isCollapsed = false
        isBusy = false
        updateButton()
    }

    private func applyNativeRestriction() {
        guard isEnabled, AXIsProcessTrusted(), BezelMenuVisibilityAvailable() else {
            expand()
            lastError = "Menu icon collapse is unavailable with this macOS menu-bar interface."
            return
        }
        generation += 1
        let request = generation
        if let pendingRestriction { BezelMenuVisibilityRelease(pendingRestriction) }
        pendingRestriction = nil
        isBusy = true
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let allowed = MenuVisibilityPolicy.allowedBundles(running: running, hidden: hiddenBundles, own: Bundle.main.bundleIdentifier ?? "com.bezel.utility")
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, request == generation else { return }
            expand()
            lastError = "macOS did not respond to the menu-bar request. Your icons remain visible."
        }
        pendingRestriction = BezelMenuVisibilityActivate(allowed) { [weak self] new, error in
            MainActor.assumeIsolated {
                guard let self, request == self.generation, self.isEnabled else {
                    if let new { BezelMenuVisibilityRelease(new) }
                    return
                }
                self.timeoutTask?.cancel()
                self.timeoutTask = nil
                self.pendingRestriction = nil
                self.isBusy = false
                guard let new else {
                    self.expand()
                    self.lastError = error?.localizedDescription ?? "macOS rejected the menu-bar request."
                    return
                }
                let previous = self.restriction
                self.restriction = new
                if let previous { BezelMenuVisibilityRelease(previous) }
                self.isCollapsed = true
                self.updateButton()
                self.monitorPermission()
            }
        }
    }

    private func monitorPermission() {
        guard permissionTask == nil else { return }
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, self.isCollapsed else { return }
                if !AXIsProcessTrusted() {
                    self.expand()
                    self.lastError = "Accessibility access was removed. Menu icons have been restored."
                    return
                }
            }
        }
    }

    @objc private func pressed(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            showShelf()
        } else { toggle() }
    }

    func showShelf() {
        guard let button = toggleItem?.button else { return }
        if popover?.isShown == true { popover?.close(); return }
        refresh()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuIconShelf(manager: self))
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func open(_ extra: MenuExtra, app: MenuBarApp) {
        expand()
        popover?.close()
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, self?.isEnabled == true else { return }
            let success = await Task.detached(priority: .userInitiated) { MenuBarInventory.press(extra, app: app) }.value
            if !success { self?.lastError = "The menu icon changed or does not support Accessibility actions. Refresh the icon list." }
            self?.openTask = nil
        }
    }

    private func updateButton() {
        toggleItem?.button?.image = NSImage(systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right", accessibilityDescription: isCollapsed ? "Show menu icons" : "Collapse menu icons")
        toggleItem?.button?.toolTip = "Click to \(isCollapsed ? "show" : "collapse") menu icons. Option-click or right-click for the icon shelf."
    }
}

struct MenuBarManagerControls: View {
    @Bindable var manager: MenuBarManager
    var body: some View {
        Toggle("Collapse other apps’ menu icons", isOn: $manager.isEnabled)
        if manager.isEnabled {
            HStack {
                Button(manager.isCollapsed ? "Show Icons" : "Collapse Icons") { manager.toggle() }
                Button("Icon Shelf") { manager.showShelf() }
                Button("Refresh") { manager.refresh() }
            }
            Text("Choose icons from the chevron’s shelf. Click the chevron to collapse them, and Option-click to open the shelf. Opening a hidden icon reveals the menu bar and invokes its original menu.").font(.caption).foregroundStyle(.secondary)
            if let error = manager.lastError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct MenuIconShelf: View {
    @Bindable var manager: MenuBarManager
    private var native: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Menu Icons").font(.headline)
                Spacer()
                Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh icons")
            }
            if manager.apps.isEmpty {
                Text("No accessible third-party menu icons found.").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(manager.apps) { app in
                        HStack {
                            Menu {
                                ForEach(app.extras) { extra in
                                    Button(extra.title) { manager.open(extra, app: app) }
                                }
                            } label: { Label(app.name, systemImage: "menubar.rectangle") }
                            .menuStyle(.borderlessButton).help("Open this app’s menu icon")
                            Spacer()
                            if native {
                                Toggle("Hide", isOn: Binding(get: { manager.hiddenBundles.contains(app.id) }, set: { manager.setHidden(app.id, $0) }))
                                    .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("Hide \(app.name)’s menu icons").help("Collapse \(app.name)’s icons")
                            }
                        }
                    }
                }
            }.frame(maxHeight: 280)
            if native {
                Text("Checked apps are hidden when collapsed. macOS system icons remain visible. This uses an experimental macOS 27 menu-bar interface.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Command-drag icons left of the divider to hide them. Keep the divider to the left of Bezel’s chevron.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = manager.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            Button(manager.isCollapsed ? "Show Icons" : "Collapse Icons") { manager.toggle() }.disabled(manager.isBusy)
        }.padding(18).frame(width: 330)
    }
}
