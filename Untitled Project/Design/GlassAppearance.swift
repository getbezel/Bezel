import SwiftUI
import AppKit

/// Keep reading surfaces opaque; glass controls refract the app's own backdrop.
struct BezelBackdrop: View {
    var tint: Color = .blue
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency && contrast != .increased {
                RadialGradient(colors: [tint.opacity(scheme == .dark ? 0.16 : 0.09), .clear],
                               center: .topTrailing, startRadius: 0, endRadius: 700)
                RadialGradient(colors: [.cyan.opacity(scheme == .dark ? 0.055 : 0.03), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 550)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct BezelGlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else { content }
    }
}

private struct BezelGlassSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color
    var interactive: Bool
    var clear: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.30 : 0.12), lineWidth: 1))
        } else if #available(macOS 26, *) {
            content.glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

private struct BezelContentSurface: ViewModifier {
    var radius: CGFloat
    var tint: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency || contrast == .increased ? 1 : scheme == .dark ? 0.70 : 0.82), in: shape)
            .overlay(shape.fill(tint.opacity(0.045)).allowsHitTesting(false))
            .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.26 : 0.075), lineWidth: contrast == .increased ? 1 : 0.5).allowsHitTesting(false))
    }
}

struct BezelActionStyle: PrimitiveButtonStyle {
    var prominent = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

extension View {
    func bezelGlass(cornerRadius: CGFloat = 22, tint: Color = .clear, interactive: Bool = false, clear: Bool = false) -> some View {
        modifier(BezelGlassSurface(radius: cornerRadius, tint: tint, interactive: interactive, clear: clear))
    }
    func bezelSurface(cornerRadius: CGFloat = 20, tint: Color = .clear) -> some View {
        modifier(BezelContentSurface(radius: cornerRadius, tint: tint))
    }
}
