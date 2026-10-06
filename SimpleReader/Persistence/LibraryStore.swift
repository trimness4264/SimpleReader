import Foundation
import CoreData

/// Individual Codable records in a versioned Core Data store, owned by the main actor.
@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var settings = AppSettings()
    private let container: NSPersistentContainer
    let root: URL

    init(root: URL? = nil, inMemory: Bool = false) throws {
        self.root = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("SimpleReader", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        for name in ["Books", "Covers", "Staging"] {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "Record"; entity.managedObjectClassName = "NSManagedObject"
        func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
            let result = NSAttributeDescription(); result.name = name; result.attributeType = type; return result
        }
        entity.properties = [attribute("key", .stringAttributeType), attribute("payload", .binaryDataAttributeType)]
        entity.uniquenessConstraints = [["key"]]
        model.entities = [entity]
        container = NSPersistentContainer(name: "SimpleReaderV1", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: self.root.appendingPathComponent("Library.sqlite"))
        description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let error = loadError { throw error }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        let records = try container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "Record"))
        for record in records {
            guard let key = record.value(forKey: "key") as? String, let payload = record.value(forKey: "payload") as? Data else { continue }
            if key == "settings" { settings = try JSONDecoder().decode(AppSettings.self, from: payload) }
            else { books.append(try JSONDecoder().decode(Book.self, from: payload)) }
        }
        try saveSettings(settings) // persist a stable device ID from the first launch
        // Staging is never a committed book. A killed import can leave files here.
        for file in (try? FileManager.default.contentsOfDirectory(at: self.root.appendingPathComponent("Staging"), includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
        let committedFiles = Set(books.flatMap { [$0.filePath] + ($0.coverPath.map { [$0] } ?? []) })
        for directory in ["Books", "Covers"] {
            for file in (try? FileManager.default.contentsOfDirectory(at: self.root.appendingPathComponent(directory), includingPropertiesForKeys: nil)) ?? [] {
                if !committedFiles.contains(directory + "/" + file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    func fileURL(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }
    func save(_ book: Book) throws {
        try write(book, key: book.id.uuidString)
        if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
        else { books.append(book) }
    }
    func saveSettings(_ settings: AppSettings) throws {
        try write(settings, key: "settings"); self.settings = settings
    }
    private func record(_ key: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Record")
        request.predicate = NSPredicate(format: "key == %@", key)
        return try container.viewContext.fetch(request).first
    }
    private func write<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let context = container.viewContext
        do {
            let object = try record(key) ?? NSEntityDescription.insertNewObject(forEntityName: "Record", into: context)
            object.setValue(key, forKey: "key"); object.setValue(data, forKey: "payload")
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func delete(_ book: Book) throws {
        try delete([book])
    }
    func delete(_ candidates: [Book]) throws {
        let ids = Set(candidates.map(\.id))
        let deletedBooks = books.filter { ids.contains($0.id) }
        guard !deletedBooks.isEmpty else { return }
        // Commit deletion first; cleanup is recoverable and never leaves a live record with a missing file.
        let context = container.viewContext
        do {
            for book in deletedBooks {
                if let record = try record(book.id.uuidString) { context.delete(record) }
            }
            try context.save()
        } catch { context.rollback(); throw error }
        books.removeAll { ids.contains($0.id) }
        for book in deletedBooks {
            try? FileManager.default.removeItem(at: fileURL(book.filePath))
            if let path = book.coverPath { try? FileManager.default.removeItem(at: fileURL(path)) }
        }
    }
}
