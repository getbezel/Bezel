import SwiftUI

enum BezelModule: String, CaseIterable, Identifiable {
    case overview, stack, airBridge, aperture, grid, scope, monolith, shelf, lens, dragWheel, tether, pulse, border, cleaning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .stack: "Stack"
        case .airBridge: "AirBridge"
        case .aperture: "Aperture"
        case .grid: "Grid"
        case .scope: "Scope"
        case .monolith: "Monolith"
        case .shelf: "Shelf"
        case .lens: "Lens"
        case .dragWheel: "DragWheel"
        case .tether: "Tether"
        case .pulse: "Pulse"
        case .border: "Border"
        case .cleaning: "Cleaning"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .stack: "square.3.layers.3d"
        case .airBridge: "waveform"
        case .aperture: "rectangle.topthird.inset.filled"
        case .grid: "rectangle.split.2x2"
        case .scope: "chart.pie"
        case .monolith: "moon"
        case .shelf: "tray"
        case .lens: "viewfinder"
        case .dragWheel: "arrow.triangle.2.circlepath"
        case .tether: "battery.75percent"
        case .pulse: "cup.and.saucer"
        case .border: "rectangle.dashed"
        case .cleaning: "keyboard"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: "Your workspace, a little more capable."
        case .stack: "Everything you copy, within reach."
        case .airBridge: "A different destination for every sound."
        case .aperture: "Small moments. Right at the top."
        case .grid: "A place for every window."
        case .scope: "See what’s taking up space."
        case .monolith: "Make room for a single thought."
        case .shelf: "Put it here. Pick it up anywhere."
        case .lens: "If you can see it, you can copy it."
        case .dragWheel: "A new format, with a drag."
        case .tether: "A closer look at your battery."
        case .pulse: "Keep your Mac up for the task."
        case .border: "Find your focus at a glance."
        case .cleaning: "A clean slate for your Mac."
        }
    }
    var tint: Color {
        switch self {
        case .overview, .stack, .grid: .blue
        case .airBridge, .pulse: .orange
        case .aperture, .monolith: .purple
        case .scope, .tether: .green
        case .shelf: .cyan
        case .lens: .indigo
        case .dragWheel, .cleaning: .mint
        case .border: .pink
        }
    }
    var category: String {
        switch self {
        case .overview: "WORKSPACE"
        case .stack, .shelf, .lens, .dragWheel: "CAPTURE & COLLECT"
        case .airBridge, .aperture, .grid, .monolith, .border: "WORK & FOCUS"
        case .scope, .tether, .pulse, .cleaning: "SYSTEM"
        }
    }
    var shortcut: String? {
        switch self {
        case .stack: "⌥⌘V"
        case .lens: "⇧⌘2"
        default: nil
        }
    }
}
