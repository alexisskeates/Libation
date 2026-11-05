import SwiftUI

struct BookDetailsView: View {
    @Environment(LibraryStore.self) private var store
    @State private var tags = ""
    @State private var confirmRemove = false

    var body: some View {
        if let d = store.details {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(d)
                    Divider()
                    facts(d)
                    Divider()
                    mine(d)
                    Divider()
                    status(d)
                    if !d.book.description.isEmpty {
                        Divider()
                        Text(d.book.description.strippingHTML)
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                    actions(d)
                }
                .padding(14)
            }
            .onAppear { tags = d.book.tags }
            .onChange(of: d.book.tags) { _, t in tags = t }
            .confirmationDialog("Remove “\(d.book.title)” from your Libation library?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.remove(asins: [d.book.asin]) }
            } message: {
                Text("It goes to Libation's trash bin. Files on disk are not deleted.")
            }
        } else if store.detailsAsin != nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No book selected", systemImage: "book", description: Text("Select a title to see its details."))
        }
    }

    private func header(_ d: BookDetails) -> some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(store: store, pictureId: d.book.pictureId, size: 300)
                .frame(width: 110, height: 110).clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(d.book.title).font(.title3).fontWeight(.semibold).textSelection(.enabled)
                if !d.book.subtitle.isEmpty { Text(d.book.subtitle).font(.callout).foregroundStyle(.secondary) }
                Text(d.book.authors).font(.callout)
                Text("Narrated by \(d.book.narrators)").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Stars(value: d.book.productRating.overall)
                    Text(String(format: "%.1f", d.book.productRating.overall)).font(.caption).foregroundStyle(.secondary)
                    if d.book.isSpatial { Label("Spatial", systemImage: "spatial.audio").font(.caption2).foregroundStyle(.secondary) }
                    if d.book.isAudiblePlus { Text("Plus").font(.caption2).padding(.horizontal, 4).background(.quaternary, in: Capsule()) }
                }
            }
        }
    }

    private func facts(_ d: BookDetails) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            if !d.book.seriesText.isEmpty { fact("Series", d.book.seriesText) }
            if !d.categories.isEmpty { fact("Category", d.categories.joined(separator: ", ")) }
            fact("Length", d.book.lengthText)
            fact("Purchased", d.book.dateAdded.formatted(date: .abbreviated, time: .omitted))
            if let p = d.book.datePublished { fact("Published", p.formatted(date: .abbreviated, time: .omitted)) }
            if let l = d.book.language { fact("Language", l) }
            if let p = d.book.publisher { fact("Publisher", p) }
            fact("Account", d.book.account)
            fact("ASIN", d.book.asin)
            if let ld = d.book.lastDownloaded { fact("Downloaded", ld.formatted(date: .abbreviated, time: .shortened) + (d.book.lastDownloadedVersion.map { " · v\($0)" } ?? "")) }
        }
        .font(.callout)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mine(_ d: BookDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("My Rating").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ratingRow("Overall", d.book.myRating.overall) { Rating(overall: $0, performance: d.book.myRating.performance, story: d.book.myRating.story) }
                ratingRow("Performance", d.book.myRating.performance) { Rating(overall: d.book.myRating.overall, performance: $0, story: d.book.myRating.story) }
                ratingRow("Story", d.book.myRating.story) { Rating(overall: d.book.myRating.overall, performance: d.book.myRating.performance, story: $0) }
            }
            Text("Click a star to rate; click it again to lower it. Libation keeps a rating once set, so it cannot be cleared to zero.")
                .font(.caption2).foregroundStyle(.tertiary)
            Text("Tags").font(.headline).padding(.top, 4)
            TextField("space-separated, e.g. scifi favourite", text: $tags)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if tags != d.book.tags { store.updateUserItem(asins: [d.book.asin], tags: tags) } }
            Text("Tag “hidden” dims the row in the grid. Press return to save.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func ratingRow(_ label: String, _ value: Float, make: @escaping (Float) -> Rating) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).font(.callout).gridColumnAlignment(.trailing)
            StarsEditor(value: value) { store.updateUserItem(asins: [store.details?.book.asin ?? ""], rating: make($0)) }
        }
    }

    private func status(_ d: BookDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Liberation").font(.headline)
            Picker("Audiobook", selection: Binding(get: { d.book.bookStatus }, set: { store.updateUserItem(asins: [d.book.asin], bookStatus: $0) })) {
                Text("Downloaded").tag("Liberated")
                Text("Download Pending").tag("NotLiberated")
                if d.book.bookStatus == "Error" { Text("Error").tag("Error") }
                if d.book.bookStatus == "PartialDownload" { Text("Partially Downloaded").tag("PartialDownload") }
            }
            if d.hasPdf, let pdf = d.book.pdfStatus {
                Picker("PDF", selection: Binding(get: { pdf }, set: { store.updateUserItem(asins: [d.book.asin], pdfStatus: $0) })) {
                    Text("Downloaded").tag("Liberated")
                    Text("Download Pending").tag("NotLiberated")
                }
            }
            Text("Set to Download Pending to fetch it again on the next Liberate; set to Downloaded to skip it.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    private func actions(_ d: BookDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { store.liberate([d.book.asin]) } label: { Label(d.book.audioExists ? "Re-download" : "Liberate", systemImage: "arrow.down.circle") }
                    .disabled(d.book.absentFromLastScan)
                if let path = d.filePath {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Label("Show in Finder", systemImage: "folder") }
                }
            }
            HStack {
                Button { if let u = URL(string: d.audibleUrl) { NSWorkspace.shared.open(u) } } label: { Label("Open in Audible", systemImage: "safari") }
                Button(role: .destructive) { confirmRemove = true } label: { Label("Remove…", systemImage: "trash") }
            }
        }
        .controlSize(.small)
    }
}

extension String {
    var strippingHTML: String {
        guard let data = data(using: .utf8),
              let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { return self }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
