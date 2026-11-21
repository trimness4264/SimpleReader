import Foundation

struct SyncDestination: Hashable, Codable {
    let url: URL
    let username: String
    let document: String

    init(settings: SyncSettings, book: Book) {
        url = settings.url
        username = settings.username
        document = settings.filenameMatching ? book.identity.filenameMD5 : book.identity.partialMD5
    }
}

struct SyncLocalVersion: Equatable, Codable {
    let revision: UUID?
    let position: ReadingPosition?

    init(_ book: Book) {
        revision = book.positionRevision
        position = book.position
    }
}

struct SyncUpload: Equatable, Codable {
    let destination: SyncDestination
    let version: SyncLocalVersion
    let previous: RemoteProgress?
    var expected: RemoteProgress

    func confirms(_ remote: RemoteProgress) -> Bool {
        // The document is implicit in GET responses from some compatible servers.
        // Lua JSON encoding can round the least significant digits of the percentage.
        guard let percentage = remote.percentage, let sent = expected.percentage else { return false }
        return (remote.document ?? destination.document) == destination.document
            && remote.progress == expected.progress && abs(percentage - sent) < 1e-12
            && remote.device == expected.device && remote.device_id == expected.device_id
            && (expected.timestamp.map { remote.timestamp == $0 } ?? (remote != previous))
    }
}

enum SyncPolicy {
    struct UploadPosition: Equatable {
        let pointer: String
        let percentage: Double
    }

    enum Decision: Equatable {
        case unchanged, upload(UploadPosition), download(RemoteProgress), conflict(RemoteProgress), missingUploadPosition
    }

    static func decide(book: Book, remote: RemoteProgress?, resolvingConflict: Bool = false) -> Decision {
        if resolvingConflict { return uploadDecision(for: book) }
        if let remote, !matchesBaseline(book, remote) {
            return book.pendingSync ? .conflict(remote) : .download(remote)
        }
        guard book.pendingSync else { return .unchanged }
        return uploadDecision(for: book)
    }

    private static func matchesBaseline(_ book: Book, _ remote: RemoteProgress) -> Bool {
        book.remoteBaseline == remote.fingerprint || book.remoteBaseline == remote.legacyFingerprint
    }

    private static func uploadDecision(for book: Book) -> Decision {
        guard let position = book.position, (0...1).contains(position.progression) else { return .missingUploadPosition }
        let pointer: String
        switch book.format {
        case .pdf:
            guard let page = position.pdfPage, (0..<Int.max).contains(page) else { return .missingUploadPosition }
            pointer = String(page + 1)
        case .epub:
            guard let xpointer = position.xpointer, xpointer.hasPrefix("/body/DocFragment") else { return .missingUploadPosition }
            pointer = xpointer
        }
        return .upload(UploadPosition(pointer: pointer, percentage: position.progression))
    }
}
