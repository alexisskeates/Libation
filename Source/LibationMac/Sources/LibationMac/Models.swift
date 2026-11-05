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
    var id: String { accountId + (locale ?? "") }
    var accountId: String
    var accountName: String?
    var locale: String?
    var libraryScan: Bool
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
