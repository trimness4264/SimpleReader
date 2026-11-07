import XCTest
@testable import SimpleReader

extension XCTestCase {
    func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor func library(inMemory: Bool = true) throws -> LibraryStore {
        try LibraryStore(root: temporaryDirectory(), inMemory: inMemory)
    }
}

func readingPosition(_ page: Int = 2) -> ReadingPosition {
    ReadingPosition(progression: 0.25, pdfPage: page, updatedAt: Date(timeIntervalSince1970: 100))
}

func sampleBook(position: ReadingPosition? = readingPosition()) -> Book {
    let id = UUID()
    return Book(id: id, title: "Sample", author: "Reader", originalFilename: "sample.pdf",
        filePath: "Books/\(id).pdf", format: .pdf,
        identity: BookIdentity(sha256: "content", partialMD5: "document", filenameMD5: "filename"),
        addedAt: Date(timeIntervalSince1970: 50), position: position)
}
