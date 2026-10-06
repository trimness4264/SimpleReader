import Foundation
import PDFKit
import UIKit
import Combine

/// Own incoming documents independently of the lifetime of the presenting view.
@MainActor final class SharedBookImportCoordinator: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published var message: String?
    @Published var error: String?
    private let importer: BookImportService
    private let inbox: URL
    private var importing: Set<URL> = []
    private var scanned: Set<URL> = []
    private var completedInbox: Set<URL> = []

    init(importer: BookImportService, inbox: URL? = nil) {
        self.importer = importer
        self.inbox = inbox ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Inbox", isDirectory: true)
    }

    @discardableResult func receive(_ url: URL) -> Task<Void, Never>? {
        guard url.isFileURL else { return nil }
        let source = url.standardizedFileURL
        guard !importing.contains(source) else { return nil }
        if completedInbox.contains(source) {
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            completedInbox.remove(source)
        }
        // Acquire access in the URL callback, before deferring any work to a Task.
        let access = source.startAccessingSecurityScopedResource()
        if pendingCount == 0 { message = nil; error = nil }
        importing.insert(source)
        pendingCount += 1
        return Task {
            defer {
                if access { source.stopAccessingSecurityScopedResource() }
                importing.remove(source)
                pendingCount -= 1
            }
            do {
                let book = try await importer.importBook(from: source)
                message = "《\(book.title)》已加入书库，可以打开阅读。"
                // Only remove the system's disposable copy after a successful commit.
                if source.deletingLastPathComponent().resolvingSymlinksInPath() == inbox.resolvingSymlinksInPath() {
                    completedInbox.insert(source)
                    scanned.remove(source)
                    try? FileManager.default.removeItem(at: source)
                }
            } catch {
                self.error = "\(source.lastPathComponent)：导入失败，\(error.localizedDescription)"
            }
        }
    }

    @discardableResult func recoverInbox() -> [Task<Void, Never>] {
        // Copy-to-app documents can already be in Inbox when a scene connects.
        // Recover them even if SwiftUI has not delivered the initial openURL event.
        let files = (try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        var tasks: [Task<Void, Never>] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let source = file.standardizedFileURL
            guard BookFormat(rawValue: source.pathExtension.lowercased()) != nil,
                  scanned.insert(source).inserted else { continue }
            if let task = receive(source) { tasks.append(task) }
        }
        return tasks
    }
}

@MainActor final class BookImportService {
    private let store: LibraryStore
    private let readium: ReadiumService
    init(store: LibraryStore, readium: ReadiumService) { self.store = store; self.readium = readium }

    func importBook(from source: URL, filename: String? = nil) async throws -> Book {
        let name = filename ?? source.lastPathComponent
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
