import SwiftUI

struct ModuleIcon: View {
    let module: BezelModule
    var size: CGFloat = 36
    var body: some View {
        Image(systemName: module.symbol)
            .font(.system(size: size * 0.47, weight: .medium))
            .foregroundStyle(module.tint)
            .frame(width: size, height: size)
            .background(module.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let title: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(.system(size: 10, weight: .medium))
        }.foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.07), in: Capsule())
    }
}

struct BezelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.065), lineWidth: 1))
    }
}

struct SmallSectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
    }
}
