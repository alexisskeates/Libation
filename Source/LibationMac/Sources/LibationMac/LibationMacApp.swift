import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` has no bundle, so make sure we get a Dock icon and focus.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        HostProcess.shared.stop()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LibationMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = LibraryStore()

    var body: some Scene {
        WindowGroup("Libation") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Reload Library") { Task { await store.reload() } }.keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView().environment(store)
        }
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        Form {
            if let s = store.status {
                LabeledContent("Libation files", value: s.libationFiles)
                LabeledContent("Books folder", value: s.booksDirectory ?? "—")
                LabeledContent("Core version", value: s.version)
            }
            if let c = store.client {
                LabeledContent("Host", value: c.baseURL.absoluteString)
            }
            LabeledContent("Host log") {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([HostProcess.shared.logURL]) }
            }
            Text("Settings are still edited in Libation's own Settings.json for now.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
