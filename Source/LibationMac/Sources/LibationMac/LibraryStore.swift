import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    enum Connection: Equatable { case connecting, connected, failed(String) }

    var connection: Connection = .connecting
    var status: HostStatus?
    var books: [Book] = []
    var queue: QueueSnapshot = .empty
    var scan: ScanState = .idle
    var alerts: [HostAlert] = []
    var lastError: String?
    var searchText = "" { didSet { scheduleSearch() } }
    var sortOrder: [KeyPathComparator<Book>] = [KeyPathComparator(\Book.dateAdded, order: .reverse)]

    private(set) var client: HostClient?
    private var searchMatches: Set<String>?
    private var searchTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private let coverCache = NSCache<NSString, NSImage>()

    var visibleBooks: [Book] {
        let filtered = searchMatches.map { m in books.filter { m.contains($0.asin) } } ?? books
        return filtered.sorted(using: sortOrder)
    }
    var pendingBooks: [Book] { books.filter(\.isPending) }
    var currentAlert: HostAlert? { alerts.first }

    func connect() {
        connection = .connecting
        Task {
            do {
                let c = try await HostProcess.shared.start()
                client = c
                status = try await c.status()
                books = try await c.library()
                queue = try await c.queue()
                scan = try await c.scanState()
                connection = .connected
                NSLog("LibationMac connected to %@: %d books, %d queued", c.baseURL.absoluteString, books.count, queue.items.count)
                listen(c)
            } catch {
                NSLog("LibationMac connect failed: %@", error.localizedDescription)
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func listen(_ c: HostClient) {
        eventTask?.cancel()
        eventTask = Task {
            do {
                for try await ev in c.events() {
                    guard !Task.isCancelled else { return }
                    handle(ev)
                }
                NSLog("LibationMac event stream closed")
                connection = .failed("Host connection closed.")
            } catch is CancellationError {
            } catch {
                NSLog("LibationMac event stream failed: %@", error.localizedDescription)
                connection = .failed(error.localizedDescription)
            }
        }
    }

    private func handle(_ ev: SSEEvent) {
        let data = Data(ev.data.utf8)
        switch ev.name {
        case "queue":
            if let q = try? JSONDecoder.libation.decode(QueueSnapshot.self, from: data) { queue = q }
        case "scan":
            if let s = try? JSONDecoder.libation.decode(ScanState.self, from: data) {
                scan = s
                if !s.scanning { scheduleReload() }
            }
        case "library":
            scheduleReload()
        case "alert":
            if let a = try? JSONDecoder.libation.decode(HostAlert.self, from: data) { alerts.append(a) }
        default:
            break
        }
    }

    func dismissAlert() { if !alerts.isEmpty { alerts.removeFirst() } }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        guard let client else { return }
        do {
            books = try await client.library()
            status = try await client.status()
            if searchMatches != nil { await runSearch() }
        } catch { lastError = error.localizedDescription }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard let client, !q.isEmpty else { searchMatches = nil; return }
        do { searchMatches = Set(try await client.search(q)) } catch { lastError = error.localizedDescription }
    }

    func liberate(_ asins: [String]) {
        guard let client, !asins.isEmpty else { return }
        Task {
            do { queue = try await client.liberate(asins).snapshot } catch { lastError = error.localizedDescription }
        }
    }
    func liberateAllPending() { liberate(pendingBooks.map(\.asin)) }

    func cancel(_ asin: String) {
        guard let client else { return }
        Task { do { queue = try await client.cancel(asin) } catch { lastError = error.localizedDescription } }
    }
    func cancelAll() {
        guard let client else { return }
        Task { do { queue = try await client.cancelAll() } catch { lastError = error.localizedDescription } }
    }

    func scanLibrary() {
        guard let client else { return }
        Task {
            do { scan = try await client.scan() } catch { lastError = error.localizedDescription }
        }
    }

    func cover(_ pictureId: String?, size: Int) async -> NSImage? {
        guard let pictureId, let client else { return nil }
        let key = "\(pictureId)@\(size)" as NSString
        if let cached = coverCache.object(forKey: key) { return cached }
        guard let data = try? await client.coverData(pictureId: pictureId, size: size), let img = NSImage(data: data) else { return nil }
        coverCache.setObject(img, forKey: key)
        return img
    }
}
