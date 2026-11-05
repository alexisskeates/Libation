import SwiftUI

/// Libation's settings, rendered from what the host describes: one row per Configuration property,
/// grouped into the same tabs as the other front ends. Changes save immediately, as they do there.
struct SettingsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var tab: String = "Important"

    private var groups: [String] {
        var seen: [String] = []
        for s in store.settings where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(groups, id: \.self) { group in
                SettingsGroupView(group: group)
                    .tabItem { Label(group, systemImage: icon(for: group)) }
                    .tag(group)
            }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("About")
        }
        .frame(width: 640, height: 520)
        .overlay(alignment: .bottom) {
            if let err = store.settingsError {
                Text(err).font(.caption).foregroundStyle(.white).padding(6)
                    .background(.red, in: RoundedRectangle(cornerRadius: 6)).padding(8)
            }
        }
        .task { await store.loadSettings() }
    }

    private func icon(for group: String) -> String {
        switch group {
        case "Important": return "star"
        case "Import": return "square.and.arrow.down"
        case "Download & Decrypt": return "lock.open"
        case "Audio": return "waveform"
        case "Audiobookshelf": return "books.vertical"
        default: return "gearshape"
        }
    }
}

private struct SettingsGroupView: View {
    let group: String
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Form {
            ForEach(store.settings.filter { $0.group == group }) { setting in
                SettingRow(setting: setting)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingRow: View {
    let setting: Setting
    @Environment(LibraryStore.self) private var store
    @State private var text = ""

    private var label: String {
        var d = setting.description.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        if let q = d.firstIndex(of: "?"), setting.type == "bool" { d = String(d[...q]) }   // keep the question, drop the explanation
        return d
    }

    var body: some View {
        Group {
            switch setting.type {
            case "bool":
                Toggle(label, isOn: Binding(get: { setting.value.boolValue }, set: { store.setSetting(setting.name, .bool($0)) }))
            case "enum":
                Picker(label, selection: Binding(get: { setting.value.stringValue }, set: { store.setSetting(setting.name, .string($0)) })) {
                    ForEach(setting.options ?? []) { Text($0.label).tag($0.value) }
                }
            case "int":
                LabeledContent(label) {
                    TextField("", value: Binding(get: { setting.value.intValue }, set: { store.setSetting(setting.name, .int($0)) }), format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 110)
                }
            case "float":
                LabeledContent(label) {
                    TextField("", value: Binding(get: { setting.value.doubleValue }, set: { store.setSetting(setting.name, .float($0)) }), format: .number)
                        .multilineTextAlignment(.trailing).frame(width: 110)
                }
            case "path":
                LabeledContent(label) {
                    HStack {
                        Text(setting.value.stringValue).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { choosePath() }.controlSize(.small)
                    }
                }
            case "secret":
                LabeledContent(label) {
                    SecureField("", text: $text).frame(width: 260).onSubmit(commitText)
                }
            default:
                LabeledContent(label) {
                    TextField("", text: $text).frame(width: 260).onSubmit(commitText)
                }
            }
        }
        .help(setting.help.isEmpty ? setting.description : setting.help)
        .onAppear { text = setting.value.stringValue }
        .onChange(of: setting.value) { _, v in text = v.stringValue }
    }

    private func commitText() {
        if text != setting.value.stringValue { store.setSetting(setting.name, .string(text)) }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: setting.value.stringValue)
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            store.setSetting(setting.name, .string(url.path))
        }
    }
}

private struct AboutSettingsView: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        Form {
            if let s = store.status {
                LabeledContent("Libation files", value: s.libationFiles)
                LabeledContent("Core version", value: s.version)
            }
            if let c = store.client { LabeledContent("Host", value: c.baseURL.absoluteString) }
            LabeledContent("Host log") {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([HostProcess.shared.logURL]) }
            }
        }
        .formStyle(.grouped)
    }
}
