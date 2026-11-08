import Foundation

@main struct DashboardTests {
    @MainActor static func main() {
        let available = ["stack", "lens", "shelf", "pulse"]
        var order = DashboardOrder(saved: ["lens", "removed", "lens", "stack"], available: available)
        precondition(order.ids == ["lens", "stack", "shelf", "pulse"], "Stale and duplicate IDs must be removed while new modules are added")
        order.move("lens", onto: "pulse")
        precondition(order.ids == ["stack", "shelf", "pulse", "lens"], "Moving forward must land in the intended slot")
        order.move("lens", onto: "stack")
        precondition(order.ids == ["lens", "stack", "shelf", "pulse"], "Moving backwards must land in the intended slot")
        let unchanged = order
        order.move("unknown", onto: "stack"); order.move("lens", onto: "unknown"); order.move("lens", onto: "lens")
        precondition(order == unchanged, "Invalid/self drops cannot damage the layout")
        order.nudge("lens", by: -1); order.nudge("pulse", by: 1)
        precondition(order == unchanged, "Moves beyond the edges are ignored")
        order.nudge("stack", by: 1)
        precondition(order.ids == ["lens", "shelf", "stack", "pulse"], "Keyboard/context-menu moves work")
        order.reset(); precondition(order.ids == available)
        var empty = DashboardOrder(saved: ["stack"], available: [])
        empty.move("stack", onto: "lens"); empty.nudge("stack", by: 1)
        precondition(empty.ids.isEmpty)
        let suite = "com.bezel.dashboard-test.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let first = DashboardLayout(available: available, preferences: preferences)
        precondition(first.isDefault)
        first.move("stack", onto: "shelf")
        let reopened = DashboardLayout(available: available + ["new-module"], preferences: preferences)
        precondition(reopened.order.ids == ["lens", "shelf", "stack", "pulse", "new-module"], "Order survives relaunch and newly added modules")
        reopened.reset()
        precondition(reopened.isDefault && preferences.object(forKey: "dashboard.moduleOrder") == nil, "Reset clears customization")
        print("Dashboard checks passed: reorder in both directions, stale/duplicate IDs, new modules, invalid drops, edge moves, accessible moves, persistence and reset.")
    }
}
