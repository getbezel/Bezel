import SwiftUI
import AppKit

@main
struct BezelApp: App {
    @NSApplicationDelegateAdaptor(BezelAppDelegate.self) private var delegate
    @State private var model = BezelModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Bezel", id: "main") {
            ContentView(model: model)
                .containerBackground(.ultraThinMaterial, for: .window)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { model.start() }
                .onOpenURL { model.handle(url: $0) }
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Bezel") {
                    openWindow(id: "about")
                }
            }
            CommandMenu("Tools") {
                Button("Open Clipboard") { model.stack.showHUD() }
                Button("Capture Text with Lens") { model.lens.startCapture() }
                Button("Start Cleaning Mode") {
                    model.selection = .cleaning
                    openWindow(id: "main")
                    model.cleaning.start()
                }
                Button("Show File Shelf") { model.shelf.show() }
                Button("Convert Files with DragWheel…") {
                    model.selection = .dragWheel
                    openWindow(id: "main")
                    model.dragWheel.chooseFiles()
                }
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
        Window("About Bezel", id: "about") {
            BezelLegalView().frame(width: 620, height: 600)
        }
        .windowResizability(.contentSize)
        Settings {
            BezelSettingsView(model: model)
                .containerBackground(.ultraThinMaterial, for: .window)
        }
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
