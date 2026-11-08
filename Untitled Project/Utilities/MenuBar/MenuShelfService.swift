import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class MenuShelfService {
    let manager = MenuBarManager()
    var isExpanded = true
    var pinned: [BezelModule] = [.stack, .lens, .shelf, .monolith, .pulse] {
        didSet { UserDefaults.standard.set(pinned.map(\.rawValue), forKey: "menu.pinned") }
    }
    init() {
        if let values = UserDefaults.standard.stringArray(forKey: "menu.pinned") {
            pinned = values.compactMap(BezelModule.init(rawValue:)).filter { $0 != .overview }
        }
    }
    func togglePin(_ module: BezelModule) {
        if pinned.contains(module) { pinned.removeAll { $0 == module } }
        else { pinned.append(module) }
    }
}
