import Foundation

// DTOs mirror Source/LibationHost/Dto.cs. Formatting lives here, data shaping lives there.

struct Rating: Codable, Hashable {
    var overall: Float
    var performance: Float
    var story: Float
}

struct SeriesLink: Codable, Hashable {
    var seriesAsin: String
    var name: String?
    var order: String?
    var index: Float
}

struct Book: Codable, Identifiable, Hashable {
    var id: String { asin }
    var asin: String
    var title: String
    var subtitle: String
    var titleWithSubtitle: String
    var description: String
    var authors: String
    var narrators: String
    var publisher: String?
    var lengthMinutes: Int
    var contentType: String
    var locale: String
    var pictureId: String?
    var isAbridged: Bool
    var isSpatial: Bool
    var datePublished: Date?
    var language: String?
    var account: String
    var dateAdded: Date
    var includedUntil: Date?
    var isAudiblePlus: Bool
    var absentFromLastScan: Bool
    var bookStatus: String
    var pdfStatus: String?
    var audioExists: Bool
    var needsBookDownload: Bool
    var needsPdfDownload: Bool
    var tags: String
    var myRating: Rating
    var productRating: Rating
    var lastDownloaded: Date?
    var lastDownloadedVersion: String?
    var series: [SeriesLink]

    var seriesText: String {
        series.compactMap { link -> String? in
            guard let name = link.name, !name.isEmpty else { return nil }
            if let order = link.order, !order.isEmpty { return "\(name) #\(order)" }
            return name
        }.joined(separator: ", ")
    }

    var lengthText: String {
        let h = lengthMinutes / 60, m = lengthMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    var isPending: Bool { needsBookDownload || needsPdfDownload }
}

struct QueueItem: Codable, Identifiable, Hashable {
    var id: String { asin }
    var asin: String
    var title: String?
    var author: String?
    var narrator: String?
    var pictureId: String?
    var status: String   // Queued | Working | Completed | Cancelled | Failed
    var result: String
    var statusText: String
    var progress: Int
    var etaSeconds: Double

    var isWorking: Bool { status == "Working" }
    var isQueued: Bool { status == "Queued" }
    var isFinished: Bool { !isWorking && !isQueued }
}

struct QueueSnapshot: Codable, Hashable {
    var running: Bool
    var queuedCount: Int
    var completedCount: Int
    var errorCount: Int
    var progress: Double
    var maxConcurrentDownloads: Int
    var items: [QueueItem]

    static let empty = QueueSnapshot(running: false, queuedCount: 0, completedCount: 0, errorCount: 0, progress: 0, maxConcurrentDownloads: 1, items: [])
}

struct ScanState: Codable, Hashable {
    var scanning: Bool
    var totalProcessed: Int?
    var newBooks: Int?
    var error: String?
    static let idle = ScanState(scanning: false, totalProcessed: nil, newBooks: nil, error: nil)
}

struct HostAlert: Codable, Identifiable, Hashable {
    var id = UUID()
    var caption: String
    var message: String
    var buttons: String
    var icon: String
    private enum CodingKeys: String, CodingKey { case caption, message, buttons, icon }
}

struct HostStatus: Codable, Hashable {
    var version: String
    var libationFiles: String
    var booksDirectory: String?
    var bookCount: Int
    var scanning: Bool
}

struct Account: Codable, Identifiable, Hashable {
    var id: String { accountId + "|" + (locale ?? "") }
    var accountId: String
    var accountName: String?
    var locale: String?
    var libraryScan: Bool
    var additionalLocales: [String]
    var hasTokens: Bool
}

struct LocaleInfo: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var countryCode: String
    var withUsername: Bool
}

struct LoginCookie: Codable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
}

/// A browser sign-in the host is waiting on. Arrives as a "login" event.
struct LoginSession: Codable, Identifiable, Hashable {
    var id: String
    var accountId: String
    var locale: String?
    var loginUrl: String
    var userAgent: String
    var cookies: [LoginCookie]
}

struct SignInResult: Codable, Hashable {
    var accountId: String
    var locale: String?
    var ok: Bool
    var error: String?
}

extension JSONDecoder {
    /// .NET writes local DateTimes without an offset and with up to seven fractional digits.
    static let libation: JSONDecoder = {
        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let local: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let s = try container.decode(String.self)
            if let d = iso.date(from: s) ?? plain.date(from: s) { return d }
            let base = s.split(separator: ".").first.map(String.init) ?? s
            if let d = local.date(from: base) { return d }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date \(s)")
        }
        return decoder
    }()
}

struct SettingOption: Codable, Hashable, Identifiable {
    var id: String { value }
    var value: String
    var label: String
}

/// Loosely typed setting value, as the host serialises Configuration properties.
enum SettingValue: Codable, Hashable {
    case bool(Bool), int(Int64), float(Double), string(String), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int64.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .float(d) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .float(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .null: try c.encodeNil()
        }
    }
    var boolValue: Bool { if case .bool(let b) = self { return b }; return false }
    var intValue: Int64 { switch self { case .int(let i): return i; case .float(let d): return Int64(d); default: return 0 } }
    var doubleValue: Double { switch self { case .float(let d): return d; case .int(let i): return Double(i); default: return 0 } }
    var stringValue: String { switch self { case .string(let s): return s; case .int(let i): return String(i); case .float(let d): return String(d); case .bool(let b): return String(b); case .null: return "" } }
}

struct Setting: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var group: String
    var type: String   // bool | int | float | enum | path | string | secret
    var value: SettingValue
    var description: String
    var help: String
    var options: [SettingOption]?
}

struct BookDetails: Codable, Hashable {
    var book: Book
    var categories: [String]
    var audibleUrl: String
    var hasPdf: Bool
    var filePath: String?
}
