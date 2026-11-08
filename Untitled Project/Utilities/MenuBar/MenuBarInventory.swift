import AppKit
import ApplicationServices

struct MenuExtra: Identifiable, Sendable {
    let id: Int
    let title: String
}

struct MenuBarApp: Identifiable, Sendable {
    let id: String
    let name: String
    let pid: pid_t
    let extras: [MenuExtra]
}

enum MenuVisibilityPolicy {
    static func allowedBundles(running: [String], hidden: Set<String>, own: String) -> [String] {
        Array(Set(running.filter { !hidden.contains($0) || $0.hasPrefix("com.apple.") } + [own])).sorted()
    }
}

/// AX objects stay local to the worker; only immutable descriptions cross actors.
enum MenuBarInventory {
    static func snapshot(apps: [MenuBarApp]) -> [MenuBarApp] {
        apps.compactMap { app in
            let children = children(of: app.pid)
            guard !children.isEmpty else { return nil }
            let extras = children.enumerated().map { index, element in
                MenuExtra(id: index, title: title(of: element) ?? app.name)
            }
            return MenuBarApp(id: app.id, name: app.name, pid: app.pid, extras: extras)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func press(_ extra: MenuExtra, app: MenuBarApp) -> Bool {
        let elements = children(of: app.pid)
        guard elements.indices.contains(extra.id),
              elements.count == app.extras.count,
              (title(of: elements[extra.id]) ?? app.name) == extra.title else { return false }
        return AXUIElementPerformAction(elements[extra.id], kAXPressAction as CFString) == .success
    }

    private static func children(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let bar = unsafeDowncast(value, to: AXUIElement.self)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &children) == .success else { return [] }
        return children as? [AXUIElement] ?? []
    }

    private static func title(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let title = value as? String, !title.isEmpty { return String(title.prefix(100)) }
        }
        return nil
    }
}
