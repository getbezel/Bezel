import SwiftUI

struct ShelfArrival {
    enum Kind { case file, image, text }

    static let displayTime: Duration = .milliseconds(1150)
    let kind: Kind
    let count: Int
    let date = Date()

    var label: String {
        if count > 1 { return "\(count) items added" }
        switch kind {
        case .file: return "File added"
        case .image: return "Image added"
        case .text: return "Text added"
        }
    }
}

/// Lives outside the empty/list switch so the very first item can finish landing.
struct ShelfCatchFeedback: View {
    let service: ShelfService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if service.isDropTargeted || service.arrival != nil {
                let arrival = service.isDropTargeted ? nil : service.arrival
                TimelineView(.animation(paused: reduceMotion || arrival == nil)) { clock in
                    let age = arrival.map { max(0, clock.date.timeIntervalSince($0.date)) } ?? 0
                    HStack(spacing: 8) {
                        Group {
                            if let arrival {
                                ShelfCatchTray(kind: arrival.kind, multiple: arrival.count > 1,
                                              age: age, opening: 0, still: reduceMotion)
                            } else {
                                ShelfAimingTray(still: reduceMotion)
                            }
                        }
                        .frame(width: 49, height: 42)
                        Text(arrival?.label ?? "Drop to add")
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.leading, 9).padding(.trailing, 17).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.16), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                    .opacity(reduceMotion || arrival == nil ? 1 : min(1, max(0, (1.15 - age) / 0.16)))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(arrival?.label ?? "Drop to add to Shelf")
            } else if service.items.isEmpty {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 9) {
                        emptyTray
                        Text("Drop something here").font(.headline)
                        Text("Files, images, and text.").font(.callout).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        emptyTray
                        Text("Drop something here").font(.headline)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var emptyTray: some View {
        ShelfCatchTray(kind: nil, multiple: false, age: 0, opening: 0, still: true)
            .frame(width: 59, height: 47)
            .accessibilityHidden(true)
    }
}

private struct ShelfAimingTray: View {
    let still: Bool
    @State private var open = false

    var body: some View {
        ShelfCatchTray(kind: nil, multiple: false, age: 0, opening: still || open ? 1 : 0, still: still)
            .onAppear { withAnimation(still ? nil : .easeOut(duration: 0.16)) { open = true } }
    }
}

struct ShelfCatchTray: View, Animatable {
    let kind: ShelfArrival.Kind?
    let multiple: Bool
    let age: Double
    nonisolated var opening: Double
    let still: Bool

    nonisolated var animatableData: Double {
        get { opening }
        set { opening = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 72, size.height / 58)
            context.translateBy(x: (size.width - 72 * scale) / 2, y: (size.height - 58 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            // The slip crosses the lip at impact. Give the tray one damped recoil.
            let travel = min(1, max(0, age / 0.36))
            let impact = max(0, age - 0.26)
            let recoil = still || kind == nil ? 0 : 5 * sin(impact * 25) * exp(-impact * 11)
            let opening = kind == nil || still ? opening : max(0, 1 - impact / 0.21)
            let lipY = 35.0 + opening * 2.0
            let backY = 26.0 - opening * 4.0
            context.translateBy(x: 0, y: recoil)

            var well = Path()
            well.move(to: CGPoint(x: 8, y: lipY + 2))
            well.addLine(to: CGPoint(x: 15, y: backY + 2))
            well.addQuadCurve(to: CGPoint(x: 20, y: backY), control: CGPoint(x: 17, y: backY))
            well.addLine(to: CGPoint(x: 52, y: backY))
            well.addQuadCurve(to: CGPoint(x: 57, y: backY + 2), control: CGPoint(x: 55, y: backY))
            well.addLine(to: CGPoint(x: 64, y: lipY + 2))
            well.closeSubpath()
            context.fill(well, with: .color(.accentColor.opacity(0.22)))
            context.stroke(well, with: .color(.accentColor), lineWidth: 2)

            if let kind, !still, travel < 1 {
                var paper = context
                paper.clip(to: Path(CGRect(x: 0, y: -4, width: 72, height: 51)))
                let fall = travel * travel
                paper.translateBy(x: 23 + 13 * sin(travel * .pi / 2), y: 12 - 5 * sin(.pi * travel) + 48 * fall)
                paper.rotate(by: .degrees(-19 * (1 - travel)))
                if multiple {
                    var back = paper
                    back.translateBy(x: 3, y: -2)
                    back.rotate(by: .degrees(9))
                    back.fill(Self.slip, with: .color(.accentColor))
                }
                paper.fill(Self.slip, with: .color(.white))
                paper.draw(Text(Image(systemName: Self.symbol(for: kind))).font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(red: 0.12, green: 0.29, blue: 0.56)), at: .zero)
            }

            var lip = Path()
            lip.move(to: CGPoint(x: 8, y: lipY))
            lip.addLine(to: CGPoint(x: 25, y: lipY))
            lip.addQuadCurve(to: CGPoint(x: 31, y: lipY + 5), control: CGPoint(x: 28, y: lipY + 5))
            lip.addLine(to: CGPoint(x: 41, y: lipY + 5))
            lip.addQuadCurve(to: CGPoint(x: 47, y: lipY), control: CGPoint(x: 44, y: lipY + 5))
            lip.addLine(to: CGPoint(x: 64, y: lipY))
            lip.addLine(to: CGPoint(x: 61, y: 49))
            lip.addQuadCurve(to: CGPoint(x: 56, y: 53), control: CGPoint(x: 60, y: 53))
            lip.addLine(to: CGPoint(x: 16, y: 53))
            lip.addQuadCurve(to: CGPoint(x: 11, y: 49), control: CGPoint(x: 12, y: 53))
            lip.closeSubpath()
            context.fill(lip, with: .linearGradient(Gradient(colors: [.accentColor, .accentColor.mix(with: .black, by: 0.27)]),
                                                   startPoint: CGPoint(x: 36, y: lipY), endPoint: CGPoint(x: 36, y: 53)))
            if kind != nil && (still || age >= 0.33) {
                let alpha = still ? 1.0 : min(1, (age - 0.33) / 0.1)
                context.opacity = alpha
                context.draw(Text(Image(systemName: "checkmark")).font(.system(size: 10, weight: .bold)).foregroundColor(.white),
                             at: CGPoint(x: 36, y: 46))
            }
        }
        .accessibilityHidden(true)
    }

    private static let slip = Path(roundedRect: CGRect(x: -10, y: -11, width: 20, height: 22), cornerRadius: 3)
    private static func symbol(for kind: ShelfArrival.Kind) -> String {
        switch kind {
        case .file: "doc.fill"
        case .image: "photo.fill"
        case .text: "text.alignleft"
        }
    }
}
