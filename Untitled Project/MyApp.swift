import SwiftUI
import AppKit

@main
struct BezelApp: App {
    @NSApplicationDelegateAdaptor(BezelAppDelegate.self) private var delegate
    @State private var model = BezelModel.shared

    var body: some Scene {
        Window("Bezel", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear { model.start() }
                .onOpenURL { model.handle(url: $0) }
        }
        .defaultSize(width: 1180, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Bezel") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Bezel", .applicationVersion: "1.0",
                        .credits: NSAttributedString(string: "A little more possibility. A lot more Mac.")
                    ])
                }
            }
            CommandMenu("Tools") {
                Button("Open Clipboard") { model.stack.showHUD() }
                Button("Capture Text with Lens") { model.lens.startCapture() }
                Button("Show File Shelf") { model.shelf.show() }
                Divider()
                Button(model.monolith.isActive ? "End Focus Session" : "Start 25-Minute Focus") {
                    model.monolith.isActive ? model.monolith.stop() : model.monolith.start(minutes: 25)
                }
            }
        }
        MenuBarExtra("Bezel", systemImage: "rectangle.topthird.inset.filled") {
            BezelMenuView(model: model)
        }
        .menuBarExtraStyle(.window)
        Settings { BezelSettingsView(model: model) }
    }
}

@MainActor
final class BezelAppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false
    func applicationDidFinishLaunching(_ notification: Notification) { BezelModel.shared.start() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await BezelModel.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { BezelModel.shared.stop() }
}
