import SwiftUI

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @State private var selection = Set<String>()
    @State private var showQueue = true
    @State private var inspectorTab: InspectorTab = .details
    enum InspectorTab: String, CaseIterable { case details = "Details", queue = "Queue" }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var store = store
        Group {
            switch store.connection {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting Libation…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Could not start Libation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).font(.callout).textSelection(.enabled)
                } actions: {
                    Button("Retry") { store.connect() }
                    Button("Show Host Log") { NSWorkspace.shared.activateFileViewerSelecting([HostProcess.shared.logURL]) }
                }
            case .connected:
                libraryTable
            }
        }
        .inspector(isPresented: $showQueue) {
            VStack(spacing: 0) {
                Picker("", selection: $inspectorTab) {
                    ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(8)
                Divider()
                switch inspectorTab {
                case .details: BookDetailsView()
                case .queue: QueueView()
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
            .environment(store)   // inspector content is hosted separately; do not rely on inheritance
        }
        .onChange(of: selection) { _, sel in store.detailsAsin = sel.count == 1 ? sel.first : nil }
        .onChange(of: store.queue.items.count) { old, new in if new > old { inspectorTab = .queue; showQueue = true } }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search — Libation syntax works (e.g. -liberated)")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
        .alert(store.currentAlert?.caption ?? "", isPresented: Binding(get: { store.currentAlert != nil }, set: { if !$0 { store.dismissAlert() } }), presenting: store.currentAlert) { _ in
            Button("OK") { store.dismissAlert() }
        } message: { a in
            Text(a.message)
        }
        .sheet(item: Binding(get: { store.loginSession }, set: { if $0 == nil { store.cancelLogin() } })) { session in
            LoginWebSheet(session: session).environment(store)
        }
        .onAppear { if store.client == nil { store.connect() } }
    }

    private var libraryTable: some View {
        @Bindable var store = store
        return Table(store.visibleBooks, selection: $selection, sortOrder: $store.sortOrder) {
            TableColumn("") { book in
                CoverImage(store: store, pictureId: book.pictureId, size: 80)
                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .width(44)
            TableColumn("Status", value: \.bookStatus) { book in StatusIcon(book: book).frame(maxWidth: .infinity) }
                .width(56)
            TableColumn("Title", value: \.title) { book in
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title).fontWeight(.medium).lineLimit(1)
                    if !book.subtitle.isEmpty {
                        Text(book.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 200, ideal: 320)
            TableColumn("Authors", value: \.authors).width(min: 100, ideal: 160)
            TableColumn("Narrators", value: \.narrators).width(min: 100, ideal: 160)
            TableColumn("Series", value: \.seriesText).width(min: 80, ideal: 180)
            TableColumn("Length", value: \.lengthMinutes) { Text($0.lengthText).monospacedDigit() }.width(70)
            TableColumn("Purchased", value: \.dateAdded) { Text($0.dateAdded, format: .dateTime.day().month(.abbreviated).year()) }.width(100)
            TableColumn("My Rating", value: \.myRating.overall) { Stars(value: $0.myRating.overall) }.width(80)
            TableColumn("Tags", value: \.tags).width(min: 60, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let chosen = ids.isEmpty ? selection : ids
            Button("Liberate") { store.liberate(Array(chosen)) }
            Button("Show Details") { if let one = chosen.first { selection = [one]; inspectorTab = .details; showQueue = true } }
            Divider()
            Button("Mark as Downloaded") { store.updateUserItem(asins: Array(chosen), bookStatus: "Liberated") }
            Button("Mark as Download Pending") { store.updateUserItem(asins: Array(chosen), bookStatus: "NotLiberated") }
            Divider()
            Button("Remove from Library", role: .destructive) { store.remove(asins: Array(chosen)) }
            Divider()
            Button("Copy ASIN") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chosen.sorted().joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Open in Audible") {
                for asin in chosen { NSWorkspace.shared.open(URL(string: "https://www.audible.co.uk/pd/\(asin)")!) }
            }
        } primaryAction: { ids in
            if let one = ids.first { selection = [one]; inspectorTab = .details; showQueue = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.scanLibrary()
            } label: {
                Label("Scan", systemImage: store.scan.scanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .help("Scan your Audible library for new titles")
            .disabled(store.scan.scanning || store.connection != .connected)

            Button {
                if selection.isEmpty { store.liberateAllPending() } else { store.liberate(Array(selection)) }
            } label: {
                Label(selection.isEmpty ? "Liberate All" : "Liberate", systemImage: "arrow.down.circle")
            }
            .help(selection.isEmpty ? "Download and decrypt every pending title" : "Download and decrypt the selected titles")
            .disabled(store.connection != .connected || (selection.isEmpty && store.pendingBooks.isEmpty))

            Button {
                openWindow(id: "accounts")
            } label: {
                Label("Accounts", systemImage: "person.crop.circle")
            }
            .help("Manage Audible accounts and sign in")

            Button {
                showQueue.toggle()
            } label: {
                Label("Queue", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the process queue")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text("\(store.visibleBooks.count) of \(store.books.count) titles")
            if !store.pendingBooks.isEmpty {
                Text("·"); Text("\(store.pendingBooks.count) pending")
            }
            if store.scan.scanning {
                Text("·"); ProgressView().controlSize(.mini); Text("Scanning Audible library…")
            } else if let n = store.scan.newBooks {
                Text("·"); Text("Last scan added \(n)")
            }
            if let err = store.scan.error ?? store.lastError {
                Text("·"); Text(err).foregroundStyle(.red).lineLimit(1).help(err)
            }
            Spacer()
            if let s = store.status { Text("Libation \(s.version)").foregroundStyle(.tertiary) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }
}
