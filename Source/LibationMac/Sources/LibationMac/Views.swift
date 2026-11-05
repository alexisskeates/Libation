import SwiftUI

/// Cover art loaded through the host. Takes the store explicitly rather than from the environment:
/// macOS Table cells are hosted in their own NSHostingViews and do not reliably carry an
/// `@Observable` environment value, which crashed with "No Observable object of type LibraryStore".
struct CoverImage: View {
    let store: LibraryStore
    let pictureId: String?
    var size: Int = 80
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary).overlay(Image(systemName: "book.closed").foregroundStyle(.tertiary))
            }
        }
        .task(id: pictureId) { image = await store.cover(pictureId, size: size) }
    }
}

struct StatusIcon: View {
    let book: Book

    private var symbol: (name: String, color: Color, help: String) {
        if book.absentFromLastScan { return ("questionmark.circle", .secondary, "Not found in the last library scan") }
        switch book.bookStatus {
        case "Liberated": return ("checkmark.circle.fill", .green, "Liberated")
        case "Error": return ("exclamationmark.triangle.fill", .red, "Error during liberation")
        case "PartialDownload": return ("circle.lefthalf.filled", .yellow, "Partially downloaded")
        default: return ("arrow.down.circle", .accentColor, "Not yet downloaded")
        }
    }

    var body: some View {
        let s = symbol
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: s.name).font(.title3).foregroundStyle(s.color)
            if let pdf = book.pdfStatus {
                Image(systemName: "doc.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(pdf == "Liberated" ? Color.green : Color.orange)
                    .offset(x: 4, y: 3)
            }
        }
        .help(book.pdfStatus.map { "\(s.help) · PDF \($0 == "Liberated" ? "downloaded" : "pending")" } ?? s.help)
    }
}

struct StarsEditor: View {
    let value: Float
    let onChange: (Float) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: Float(i) <= value ? "star.fill" : "star")
                    .foregroundStyle(value > 0 ? Color.yellow : Color.secondary.opacity(0.4))
                    .onTapGesture { onChange(Float(i) == value ? 0 : Float(i)) }
            }
        }
        .font(.callout)
    }
}

struct Stars: View {
    let value: Float
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: Float(i) <= value ? "star.fill" : (Float(i) - 0.5 <= value ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: 9))
                    .foregroundStyle(value > 0 ? Color.yellow : Color.secondary.opacity(0.3))
            }
        }
    }
}

struct QueueView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Process Queue").font(.headline)
                Spacer()
                if !store.queue.items.isEmpty {
                    Button("Cancel All", role: .destructive) { store.cancelAll() }
                        .controlSize(.small)
                }
            }
            .padding()
            if store.queue.items.isEmpty {
                ContentUnavailableView("Nothing queued", systemImage: "tray", description: Text("Select books and press Liberate."))
            } else {
                List(store.queue.items) { item in
                    QueueRow(item: item)
                }
                .listStyle(.inset)
                Divider()
                HStack(spacing: 12) {
                    Label("\(store.queue.queuedCount)", systemImage: "clock").help("Queued")
                    Label("\(store.queue.completedCount)", systemImage: "checkmark").help("Completed")
                    if store.queue.errorCount > 0 {
                        Label("\(store.queue.errorCount)", systemImage: "exclamationmark.triangle").foregroundStyle(.red).help("Errors")
                    }
                    Spacer()
                    if store.queue.running { ProgressView().controlSize(.small) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal).padding(.vertical, 8)
            }
        }
    }
}

struct QueueRow: View {
    let item: QueueItem
    @Environment(LibraryStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoverImage(store: store, pictureId: item.pictureId, size: 80)
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.asin).font(.callout).fontWeight(.medium).lineLimit(1)
                Text(item.author ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if item.isWorking {
                    ProgressView(value: Double(item.progress), total: 100).controlSize(.small)
                    HStack {
                        Text(item.statusText).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        if item.etaSeconds > 0 {
                            Text(Duration.seconds(item.etaSeconds).formatted(.time(pattern: .minuteSecond)))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(item.statusText)
                        .font(.caption2)
                        .foregroundStyle(item.result == "Success" ? Color.green : (item.isQueued ? Color.secondary : Color.red))
                }
            }
            Spacer(minLength: 0)
            Button {
                store.cancel(item.asin)
            } label: {
                Image(systemName: item.isFinished ? "xmark.circle" : "stop.circle")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(item.isFinished ? "Remove" : "Cancel")
        }
        .padding(.vertical, 2)
    }
}
