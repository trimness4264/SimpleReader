import Foundation

struct BookIdentity: Codable, Equatable {
    var sha256: String
    var partialMD5: String
    var filenameMD5: String
}

enum BookFormat: String, Codable { case epub, pdf }
struct ReadingPosition: Codable, Equatable {
    var progression: Double
    var locatorJSON: String?
    var pdfPage: Int? // zero-based locally, one-based on the wire
    var xpointer: String?
    var updatedAt: Date
}
struct RemoteProgress: Codable, Equatable {
    var document: String?
    var progress: String?
    var percentage: Double?
    var timestamp: Double?
    var device: String?
    var device_id: String?

    var fingerprint: String {
        [progress ?? "", percentage.map { String($0) } ?? "", timestamp.map { String($0) } ?? "", device_id ?? ""].joined(separator: "|")
    }
}
struct Book: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var author: String
    var originalFilename: String
    var filePath: String
    var coverPath: String?
    var format: BookFormat
    var identity: BookIdentity
    var addedAt: Date
    var lastOpenedAt: Date?
    var position: ReadingPosition?
    var pendingSync = false
    var remoteBaseline: String?
}
struct OPDSServer: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var url: URL
    var username: String
}
enum ReadingLayout: String, Codable {
    case paginated, scroll
}
enum ReaderFont: String, Codable {
    case serif, system

    var familyName: String { self == .serif ? "Source Serif 4" : "-apple-system" }
    var cssStack: String {
        switch self {
        case .serif: return "'Source Serif 4', 'LXGW WenKai', serif"
        case .system: return "-apple-system, 'PingFang SC', 'Hiragino Sans GB', sans-serif"
        }
    }
}
struct ReaderSettings: Codable {
    var fontSize: Double = 110
    var theme = "system"
    var layout: ReadingLayout = .paginated
    var font: ReaderFont = .serif
    var lineHeight: Double = 1.65
    var pageMargins: Double = 1.0

    init() {}

    private enum CodingKeys: String, CodingKey { case fontSize, theme, layout, font, lineHeight, pageMargins }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 110
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        layout = try values.decodeIfPresent(ReadingLayout.self, forKey: .layout) ?? .paginated
        font = try values.decodeIfPresent(ReaderFont.self, forKey: .font) ?? .serif
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.65
        pageMargins = try values.decodeIfPresent(Double.self, forKey: .pageMargins) ?? 1.0
    }
}
struct SyncSettings: Codable {
    var url = URL(string: "https://sync.koreader.rocks")!
    var username = ""
    var enabled = false
    var filenameMatching = false
    var deviceID = UUID().uuidString
}
struct AppSettings: Codable {
    var servers: [OPDSServer] = []
    var reader = ReaderSettings()
    var sync = SyncSettings()
}
struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
