import Foundation
import PDFKit
import UIKit

@MainActor final class BookImportService {
    private let store: LibraryStore
    private let readium: ReadiumService
    init(store: LibraryStore, readium: ReadiumService) { self.store = store; self.readium = readium }

    func importBook(from source: URL, filename: String? = nil) async throws -> Book {
        let name = (filename ?? source.lastPathComponent as NSString as String)
        guard let format = BookFormat(rawValue: (name as NSString).pathExtension.lowercased()) else { throw AppFailure("请选择 EPUB 或 PDF 文件") }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let staging = store.fileURL("Staging/\(id).\(format.rawValue)")
        let finalPath = "Books/\(id).\(format.rawValue)"
        let coverPath = "Covers/\(id).jpg"
        var committed = false
        defer {
            try? FileManager.default.removeItem(at: staging)
            if !committed {
                try? FileManager.default.removeItem(at: store.fileURL(finalPath))
                try? FileManager.default.removeItem(at: store.fileURL(coverPath))
            }
        }
        try await Task.detached {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
                do { try FileManager.default.copyItem(at: coordinated, to: staging) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError as NSError? { throw error }
        }.value
        let identity = try await Task.detached { try BookHashing.identity(file: staging, filename: name) }.value
        if let existing = store.books.first(where: { $0.identity.sha256 == identity.sha256 }) { return existing }
        var title = (name as NSString).deletingPathExtension
        var author = ""
        var cover: UIImage?
        switch format {
        case .pdf:
            guard let pdf = PDFDocument(url: staging), !pdf.isEncrypted, pdf.pageCount > 0 else { throw AppFailure("PDF 损坏、为空或已加密") }
            title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? title
            author = pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? ""
            cover = pdf.page(at: 0)?.thumbnail(of: CGSize(width: 240, height: 320), for: .mediaBox)
        case .epub:
            let publication = try await readium.open(staging)
            title = publication.metadata.title ?? title
            author = publication.metadata.authors.map { $0.name }.joined(separator: ", ")
            cover = try? await publication.cover().get()
        }
        // Another concurrent import may have completed while metadata was being parsed.
        if let existing = store.books.first(where: { $0.identity.sha256 == identity.sha256 }) { return existing }
        var savedCover: String?
        if let data = cover?.jpegData(compressionQuality: 0.8) {
            try data.write(to: store.fileURL(coverPath), options: .atomic); savedCover = coverPath
        }
        try FileManager.default.moveItem(at: staging, to: store.fileURL(finalPath))
        let book = Book(id: id, title: title.isEmpty ? name : title, author: author, originalFilename: name, filePath: finalPath, coverPath: savedCover, format: format, identity: identity, addedAt: Date())
        try store.save(book); committed = true
        return book
    }
}
