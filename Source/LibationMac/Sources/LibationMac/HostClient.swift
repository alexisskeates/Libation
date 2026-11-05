import Foundation

struct SSEEvent {
    var name: String
    var data: String
}

enum HostError: LocalizedError {
    case http(Int, String)
    case notRunning
    case startupTimeout
    case exited(Int32, String)
    case hostNotFound([String])

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Host returned \(code): \(body)"
        case .notRunning: return "Libation host is not running."
        case .startupTimeout: return "Libation host did not start in time."
        case .exited(let code, let log): return "Libation host exited (\(code)).\n\(log)"
        case .hostNotFound(let tried): return "LibationHost executable not found. Looked in:\n" + tried.joined(separator: "\n")
        }
    }
}

/// Thin HTTP client for LibationHost. One instance per connection.
final class HostClient: @unchecked Sendable {
    let baseURL: URL
    let token: String?
    private let session: URLSession

    init(baseURL: URL, token: String?) {
        self.baseURL = baseURL
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, method: String = "GET", body: (any Encodable)? = nil) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HostError.http(code, String(decoding: data, as: UTF8.self)) }
        return try JSONDecoder.libation.decode(T.self, from: data)
    }

    func status() async throws -> HostStatus { try await send(request("api/status"), as: HostStatus.self) }
    func library() async throws -> [Book] { try await send(request("api/library"), as: [Book].self) }
    func accounts() async throws -> [Account] { try await send(request("api/accounts"), as: [Account].self) }
    func queue() async throws -> QueueSnapshot { try await send(request("api/queue"), as: QueueSnapshot.self) }
    func scanState() async throws -> ScanState { try await send(request("api/scan"), as: ScanState.self) }

    func search(_ q: String) async throws -> [String] {
        var comps = URLComponents(url: baseURL.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        var req = URLRequest(url: comps.url!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return try await send(req, as: [String].self)
    }

    struct LiberateResponse: Decodable { var queued: Bool; var snapshot: QueueSnapshot }
    func liberate(_ asins: [String]) async throws -> LiberateResponse {
        try await send(request("api/queue/liberate", method: "POST", body: ["asins": asins]), as: LiberateResponse.self)
    }
    func cancelAll() async throws -> QueueSnapshot { try await send(request("api/queue/cancel", method: "POST"), as: QueueSnapshot.self) }
    func cancel(_ asin: String) async throws -> QueueSnapshot { try await send(request("api/queue/\(asin)/cancel", method: "POST"), as: QueueSnapshot.self) }
    func scan(accounts: [String]? = nil) async throws -> ScanState {
        try await send(request("api/scan", method: "POST", body: ["accounts": accounts ?? []]), as: ScanState.self)
    }
    func locales() async throws -> [LocaleInfo] { try await send(request("api/locales"), as: [LocaleInfo].self) }
    func addAccount(accountId: String, locale: String, accountName: String?, libraryScan: Bool) async throws -> Account {
        struct Body: Encodable { var accountId: String; var locale: String; var accountName: String?; var libraryScan: Bool }
        return try await send(request("api/accounts", method: "POST", body: Body(accountId: accountId, locale: locale, accountName: accountName, libraryScan: libraryScan)), as: Account.self)
    }
    func updateAccount(_ a: Account, accountName: String? = nil, libraryScan: Bool? = nil) async throws -> Account {
        struct Body: Encodable { var accountName: String?; var libraryScan: Bool? }
        return try await send(request("api/accounts/\(a.accountId)/\(a.locale ?? "")", method: "PUT", body: Body(accountName: accountName, libraryScan: libraryScan)), as: Account.self)
    }
    func deleteAccount(_ a: Account) async throws {
        let (data, resp) = try await session.data(for: request("api/accounts/\(a.accountId)/\(a.locale ?? "")", method: "DELETE"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HostError.http(code, String(decoding: data, as: UTF8.self)) }
    }
    func signIn(_ a: Account) async throws {
        let (data, resp) = try await session.data(for: request("api/accounts/\(a.accountId)/\(a.locale ?? "")/signin", method: "POST"))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HostError.http(code, String(decoding: data, as: UTF8.self)) }
    }
    func pendingLogins() async throws -> [LoginSession] { try await send(request("api/login"), as: [LoginSession].self) }
    func completeLogin(_ id: String, responseUrl: String) async throws {
        let (data, resp) = try await session.data(for: request("api/login/\(id)/complete", method: "POST", body: ["responseUrl": responseUrl]))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw HostError.http(code, String(decoding: data, as: UTF8.self)) }
    }
    func cancelLogin(_ id: String) async { _ = try? await session.data(for: request("api/login/\(id)/cancel", method: "POST")) }

    func shutdown() async {
        _ = try? await session.data(for: request("api/shutdown", method: "POST"))
    }

    func coverData(pictureId: String, size: Int) async throws -> Data {
        var comps = URLComponents(url: baseURL.appending(path: "api/covers/\(pictureId)"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "size", value: String(size))]
        var req = URLRequest(url: comps.url!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw HostError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "") }
        return data
    }

    /// Server-sent events from /api/events. Ends when the host goes away.
    func events() -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, resp) = try await session.bytes(for: request("api/events"))
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw HostError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "events") }
                    var name = "message", data: [String] = []
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !data.isEmpty { continuation.yield(SSEEvent(name: name, data: data.joined(separator: "\n"))) }
                            name = "message"; data = []
                        } else if line.hasPrefix("event:") {
                            name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
