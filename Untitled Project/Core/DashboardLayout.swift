import Foundation
import Observation

/// Stable identities survive new modules, removed modules and stale preferences.
struct DashboardOrder: Equatable {
    private(set) var ids: [String]
    let defaults: [String]

    init(saved: [String], available: [String]) {
        var seen = Set<String>()
        defaults = available.filter { seen.insert($0).inserted }
        let valid = Set(defaults)
        seen.removeAll()
        ids = saved.filter { valid.contains($0) && seen.insert($0).inserted }
        ids += defaults.filter { !seen.contains($0) }
    }
    mutating func move(_ source: String, onto target: String) {
        guard source != target, let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { return }
        ids.insert(ids.remove(at: from), at: to)
    }
    mutating func nudge(_ id: String, by delta: Int) {
        guard let index = ids.firstIndex(of: id) else { return }
        let destination = index + (delta < 0 ? -1 : delta > 0 ? 1 : 0)
        guard ids.indices.contains(destination) else { return }
        move(id, onto: ids[destination])
    }
    mutating func reset() { ids = defaults }
}

@MainActor @Observable
final class DashboardLayout {
    private(set) var order: DashboardOrder
    @ObservationIgnored private let preferences: UserDefaults
    private static let key = "dashboard.moduleOrder"

    init(available: [String], preferences: UserDefaults = .standard) {
        self.preferences = preferences
        order = DashboardOrder(saved: preferences.stringArray(forKey: Self.key) ?? [], available: available)
    }
    var isDefault: Bool { order.ids == order.defaults }
    func move(_ source: String, onto target: String) {
        order.move(source, onto: target)
        save()
    }
    func nudge(_ id: String, by delta: Int) { order.nudge(id, by: delta); save() }
    func reset() { order.reset(); preferences.removeObject(forKey: Self.key) }
    private func save() { preferences.set(order.ids, forKey: Self.key) }
}
