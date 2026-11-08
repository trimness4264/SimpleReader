import XCTest
@testable import SimpleReader

@MainActor final class BookImportTests: XCTestCase {
    func testRenamedBookReusesExistingLibraryEntry() async throws {
        let store = try library()
        let importer = BookImportService(store: store, readium: ReadiumService())
        let source = try pdfFile(in: temporaryDirectory())
        let first = try await importer.importBook(from: source)

        let renamed = try await importer.importBook(from: source, filename: "renamed.pdf")

        XCTAssertEqual(renamed.id, first.id)
        XCTAssertEqual(store.books.map(\.id), [first.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.fileURL("Staging").path).isEmpty)
    }

    func testInvalidDocumentLeavesNoLibraryEntryOrPartialFiles() async throws {
        let store = try library()
        let source = try temporaryDirectory().appendingPathComponent("login.pdf")
        try Data("<html>Sign in</html>".utf8).write(to: source)
        let importer = BookImportService(store: store, readium: ReadiumService())

        do {
            _ = try await importer.importBook(from: source)
            XCTFail("A login page must not be imported as a book")
        } catch { XCTAssertEqual(error.localizedDescription, String(localized: "The PDF is damaged, empty, or encrypted.")) }

        XCTAssertTrue(store.books.isEmpty)
        for directory in ["Books", "Covers", "Staging"] {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.fileURL(directory).path).isEmpty, directory)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
