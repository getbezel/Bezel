import AppKit
import SwiftUI

@main struct WelcomePreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().date(from: "2026-10-21T18:07:00-05:00")!
        for (file, width, dark, name, email) in [
            ("welcome-dark-signed-out.png", 1000.0, true, Optional<String>.none, Optional<String>.none),
            ("welcome-dark-signed-in.png", 680.0, true, "Alex", "preview@example.com"),
            ("welcome-light.png", 680.0, false, "美咲", "preview@example.com")
        ] {
            let view = WelcomeCard(date: date, firstName: name, email: email, activeCount: 4,
                                   signIn: {}, signOut: {}, disconnect: {})
                .padding(20)
                .frame(width: width, height: 280, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = NSRect(x: 0, y: 0, width: width, height: 280)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No preview bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No preview PNG") }
            try png.write(to: destination.appendingPathComponent(file))
            window.orderOut(nil)
        }
    }
}
