import SwiftUI

struct StudioDesk: View {
    let model: BezelModel
    let inspect: (UUID?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("On your desk").font(.headline)
                Spacer()
                Button("Workspace ↗") { inspect(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            HStack(spacing: 11) {
                Button { inspect(nil) } label: {
                    VStack(spacing: 0) {
                        RidgePrint().accessibilityHidden(true)
                        HStack {
                            Image(systemName: "rectangle.3.group")
                            Text("\(model.stack.history.count) clips · \(model.shelf.count) on Shelf")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.font(.caption).padding(.horizontal, 12).frame(height: 31)
                    }.studioSurface()
                }.buttonStyle(.plain).accessibilityLabel("Open Workspace")
                VStack(spacing: 10) {
                    let item = model.shelf.items.last
                    deskCard("Latest on Shelf", symbol: "tray", title: item?.title ?? "Shelf is empty",
                             detail: item == nil ? "Open floating Shelf" : "\(model.shelf.count) on Shelf") {
                        if let item { inspect(item.id) } else { model.shelf.show() }
                    }
                    let clip = model.stack.history.first
                    deskCard("Latest clip", symbol: "doc.on.clipboard", title: clip?.title ?? "No clips yet",
                             detail: clip?.sourceName ?? "Open Stack") {
                        if let clip { inspect(clip.id) } else { model.selection = .stack }
                    }
                }.frame(width: 205)
            }.frame(height: 198)
        }
    }

    private func deskCard(_ label: String, symbol: String, title: String, detail: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(StudioColor.blue)
                    Text(label)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).studioSurface()
        }.buttonStyle(.plain)
    }
}

private struct RidgePrint: View {
    // Build the survey lines once. Resizing a window only changes the drawing transform.
    private static let lines: [Path] = (0..<84).map { row in
        let y = Double(row) / 83
        let center = 0.71 + 0.075 * sin(7 * y + 0.8)
        let peak = exp(-pow((y - 0.53) / 0.30, 2))
        var line = Path()
        for step in 0...192 {
            let x = Double(step) / 192
            let shoulder = exp(-pow((x - center) / 0.205, 2))
            let erosion = 0.71 + 0.17 * sin(24*x + 9*y) + 0.065 * sin(49*x - 13*y)
            let p = CGPoint(x: 600*x, y: 210*(0.06 + y*1.08 - shoulder*peak*erosion*0.53))
            if step == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        return line
    }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 600, y: size.height / 210)
            context.fill(Path(CGRect(x: 0, y: 0, width: 600, height: 210)),
                         with: .color(Color(red: 0.08, green: 0.22, blue: 0.52)))
            for (row, line) in Self.lines.enumerated() {
                let y = Double(row) / 83
                var fill = line
                fill.addLine(to: CGPoint(x: 600, y: 280))
                fill.addLine(to: CGPoint(x: 0, y: 280))
                fill.closeSubpath()
                context.fill(fill, with: .color(Color(red: 0.079 + y*0.018, green: 0.22 + 0.045*y, blue: 0.52 + 0.075*y)))
                context.stroke(line, with: .color(.white.opacity(row.isMultiple(of: 5) ? 0.72 : 0.34)),
                               lineWidth: row.isMultiple(of: 5) ? 0.78 : 0.46)
            }
        }
        .overlay(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .bottomLeading) {
            Text("Workspace").font(.system(size: 32, design: .serif)).foregroundStyle(.white).padding(16)
        }.clipped()
    }
}
