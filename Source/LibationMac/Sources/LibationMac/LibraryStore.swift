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
    var accounts: [Account] = []
    var locales: [LocaleInfo] = []
    var loginSession: LoginSession?
    var signInResults: [SignInResult] = []
    var signingIn: Set<String> = []
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
                accounts = try await c.accounts()
                locales = try await c.locales()
                loginSession = try await c.pendingLogins().first
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
        case "login":
            if let s = try? JSONDecoder.libation.decode(LoginSession.self, from: data) {
                loginSession = s
            } else if let closed = try? JSONDecoder.libation.decode(LoginClosed.self, from: data), loginSession?.id == closed.id {
                loginSession = nil
            }
        case "signin":
            if let r = try? JSONDecoder.libation.decode(SignInResult.self, from: data) {
                signingIn.remove(r.accountId + "|" + (r.locale ?? ""))
                signInResults.append(r)
                Task { await reloadAccounts() }
            }
        default:
            break
        }
    }

    func dismissAlert() { if !alerts.isEmpty { alerts.removeFirst() } }
    func dismissSignInResult() { if !signInResults.isEmpty { signInResults.removeFirst() } }

    private struct LoginClosed: Decodable { var id: String; var closed: Bool }

    // MARK: Accounts

    func reloadAccounts() async {
        guard let client else { return }
        do { accounts = try await client.accounts() } catch { lastError = error.localizedDescription }
    }

    func addAccount(accountId: String, locale: String, accountName: String?, libraryScan: Bool) async throws {
        guard let client else { throw HostError.notRunning }
        _ = try await client.addAccount(accountId: accountId, locale: locale, accountName: accountName, libraryScan: libraryScan)
        await reloadAccounts()
    }

    func update(_ account: Account, accountName: String? = nil, libraryScan: Bool? = nil) {
        guard let client else { return }
        Task {
            do { _ = try await client.updateAccount(account, accountName: accountName, libraryScan: libraryScan); await reloadAccounts() }
            catch { lastError = error.localizedDescription }
        }
    }

    func delete(_ account: Account) {
        guard let client else { return }
        Task {
            do { try await client.deleteAccount(account); await reloadAccounts() }
            catch { lastError = error.localizedDescription }
        }
    }

    func signIn(_ account: Account) {
        guard let client else { return }
        signingIn.insert(account.id)
        Task {
            do { try await client.signIn(account) }
            catch { signingIn.remove(account.id); lastError = error.localizedDescription }
        }
    }

    func completeLogin(responseUrl: String) {
        guard let client, let session = loginSession else { return }
        Task {
            do { try await client.completeLogin(session.id, responseUrl: responseUrl) }
            catch { lastError = error.localizedDescription }
            loginSession = nil
        }
    }

    func cancelLogin() {
        guard let client, let session = loginSession else { return }
        loginSession = nil
        Task { await client.cancelLogin(session.id) }
    }

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
