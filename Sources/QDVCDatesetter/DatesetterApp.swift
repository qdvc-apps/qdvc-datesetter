import AppKit
import SwiftUI

@main
struct DatesetterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // One window: the list of photos and the date to give them.
        Window("QDVC Datesetter", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 780, minHeight: 440)
        }
        .defaultSize(width: 1040, height: 660)
        .commands {
            DatesetterCommands(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than
        // from the .app bundle, so the app gets a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Photos dropped on the Dock icon, or opened with Open With.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Don't quit half-way through writing a photo.
        AppModel.shared.isApplying ? .terminateCancel : .terminateNow
    }
}

struct DatesetterCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Photos…") { model.showImporter = true }
                .keyboardShortcut("o")
                .disabled(model.isApplying)
        }
        CommandMenu("Photos") {
            Button("Use Date of Selected Photo") { model.useSelectedPhotoDate() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.selectedPhotoDate == nil)
            Button("Set Date to Now") { model.setDateToNow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Remove from List") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty || model.isApplying)
            Button("Clear List") { model.clear() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.photos.isEmpty || model.isApplying)
            Divider()
            Button("Set Date…") { model.requestApply() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canApply)
        }
        // There is no help book; drop the menu item that would say so.
        CommandGroup(replacing: .help) {}
    }
}
