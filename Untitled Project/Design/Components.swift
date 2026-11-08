import SwiftUI

struct ModuleIcon: View {
    let module: BezelModule
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: module.symbol)
            .font(.system(size: size * 0.47, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(module.tint)
            .frame(width: size, height: size)
            .background(module.tint.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(module.tint.opacity(0.14), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.caption.weight(.medium))
        }.foregroundStyle(color)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .bezelGlass(cornerRadius: 100, tint: color.opacity(0.05))
    }
}

struct BezelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bezelSurface(cornerRadius: 22)
    }
}

struct SmallSectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
    }
}
