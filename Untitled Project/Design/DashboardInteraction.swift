import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    static let bezelDashboardModule = UTType(exportedAs: "com.bezel.utility.dashboard-module", conformingTo: .data)
}

/// A private typed drag keeps dashboard rearrangement separate from file/text drops.
struct DashboardModuleTransfer: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bezelDashboardModule)
    }
}

struct DashboardCardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct DashboardCardSurface: ViewModifier {
    let tint: Color
    var targeted = false
    @State private var hovered = false
    @State private var pointer = CGPoint.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        content
            .bezelSurface(cornerRadius: 22, tint: hovered || targeted ? tint : .clear)
            .overlay {
                if hovered && !reduceMotion && !reduceTransparency && contrast != .increased {
                    GeometryReader { proxy in
                        RadialGradient(colors: [tint.opacity(0.10), .clear],
                            center: UnitPoint(x: pointer.x / max(proxy.size.width, 1), y: pointer.y / max(proxy.size.height, 1)),
                            startRadius: 0, endRadius: 150)
                    }.clipShape(shape).allowsHitTesting(false)
                }
            }
            .overlay(shape.strokeBorder(tint.opacity(targeted ? 0.75 : hovered ? 0.28 : 0), lineWidth: targeted ? 2 : 1).allowsHitTesting(false))
            .shadow(color: .black.opacity(hovered && !reduceMotion ? 0.08 : 0), radius: 10, y: 5)
            .offset(y: hovered && !reduceMotion ? -2 : 0)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .onContinuousHover { phase in
                if case .active(let point) = phase, !reduceMotion && !reduceTransparency { pointer = point }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: targeted)
    }
}
