import AppKit
import SwiftUI

/// Runs a display timeline only when text overflows its available width.
struct MarqueeText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private var singleLine: String { text.components(separatedBy: .newlines).joined(separator: " ") }
    private var textWidth: CGFloat { (singleLine as NSString).size(withAttributes: [.font: font]).width }

    var body: some View {
        GeometryReader { geometry in
            if reduceMotion || textWidth <= geometry.size.width {
                Text(singleLine).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(started) - 0.35)
                    let distance = textWidth + 32
                    let offset = CGFloat(elapsed * 28).truncatingRemainder(dividingBy: distance)
                    HStack(spacing: 32) {
                        ForEach(0..<2) { _ in
                            Text(singleLine).font(.system(size: 12, weight: .medium)).fixedSize()
                                .frame(width: textWidth, alignment: .leading)
                        }
                    }.offset(x: -offset)
                        .frame(height: geometry.size.height)
                }
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onChange(of: text) { _, _ in started = Date() }
        .onAppear { started = Date() }
    }
}
