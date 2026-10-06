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
struct ReaderSettings: Codable {
    var fontSize: Double = 110
    var theme = "light"
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
