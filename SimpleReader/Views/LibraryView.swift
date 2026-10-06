import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let environment: AppEnvironment
    @ObservedObject private var store: LibraryStore
    @State private var importing = false
    @State private var busy = false
    @State private var importingFilename: String?
    @State private var importMessage: String?
    @State private var importedBook: Book?
    @State private var error: String?
    @State private var selected: Book?
    @State private var deleting: Book?
    @State private var recentOnly = false
    init(environment: AppEnvironment) { self.environment = environment; store = environment.store }
    private var books: [Book] {
        store.books.filter { !recentOnly || $0.lastOpenedAt != nil }.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if busy {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在导入：\(importingFilename ?? "图书")").font(.callout)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = importMessage {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).font(.callout)
                        HStack {
                            if let book = importedBook {
                                Button("打开阅读") { selected = book }
                            }
                            Spacer()
                            Button("收起") { importMessage = nil; importedBook = nil }
                        }
                    }.padding().background(Color.accentColor.opacity(0.1)).cornerRadius(12)
                }
                Picker("显示", selection: $recentOnly) { Text("全部图书").tag(false); Text("最近阅读").tag(true) }.pickerStyle(.segmented)
                if books.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.system(size: 48)).foregroundColor(.secondary)
                        Text(recentOnly ? "还没有阅读记录" : "你的书库，从一本书开始").font(.title3)
                        Text("导入 EPUB 或 PDF，也可以从在线书库下载。").foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button("导入图书") { importing = true }.buttonStyle(.borderedProminent).disabled(busy)
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 200), spacing: 20)], alignment: .leading, spacing: 24) {
                    ForEach(books) { book in
                        Button { selected = book } label: { BookTile(book: book, root: store.root) }
                            .buttonStyle(.plain)
                            .contextMenu { Button(role: .destructive) { deleting = book } label: { Label("删除图书", systemImage: "trash") } }
                    }
                }
            }.padding(20)
        }
        .navigationTitle("书库")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { if busy { ProgressView() } else { Button { importing = true } label: { Image(systemName: "plus") }.accessibilityLabel("导入图书") } } }
        .sheet(isPresented: $importing) {
            DocumentImportPicker { files in
                importing = false
                Task { await importFiles(files) }
            }
        }
        .fullScreenCover(item: $selected) { book in ReaderView(bookID: book.id, environment: environment) }
        .alert("删除图书？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { book in
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                // Use the presented value: iOS 15 can clear the binding before this action runs.
                do { try store.delete(book) } catch { self.error = error.localizedDescription }
                deleting = nil
            }
        } message: { _ in Text("移除本机文件和阅读记录，服务器上的图书会保留。") }
        .errorAlert($error)
    }
    @MainActor private func importFiles(_ files: [URL]) async {
        guard !busy, !files.isEmpty else { return }
        busy = true; importMessage = nil; importedBook = nil; recentOnly = false
        defer { busy = false; importingFilename = nil }
        var messages: [String] = []
        for file in files {
            importingFilename = file.lastPathComponent
            let previousIDs = Set(store.books.map(\.id))
            do {
                let book = try await environment.importer.importBook(from: file)
                importedBook = book
                messages.append(previousIDs.contains(book.id) ? "\(file.lastPathComponent)：已在书库中，无需重复导入。" : "已导入《\(book.title)》。")
            } catch {
                messages.append("\(file.lastPathComponent)：导入失败，\(error.localizedDescription)")
            }
        }
        importMessage = messages.joined(separator: "\n")
    }
}

// Receive the UIKit delegate directly rather than depending on SwiftUI's
// fileImporter presentation and completion handling across system versions.
private struct DocumentImportPicker: UIViewControllerRepresentable {
    let onPicked: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let epub = UTType(importedAs: "org.idpf.epub-container")
        // Import mode creates an app-accessible copy, including for iCloud and
        // third-party providers. BookImportService validates and stages it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, epub], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPicked: ([URL]) -> Void
        init(onPicked: @escaping ([URL]) -> Void) { self.onPicked = onPicked }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPicked(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPicked([]) }
    }
}
private struct BookTile: View {
    let book: Book
    let root: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.88, green: 0.9, blue: 0.85))
                if let path = book.coverPath, let image = UIImage(contentsOfFile: root.appendingPathComponent(path).path) {
                    Image(uiImage: image).resizable().scaledToFit().padding(4)
                } else {
                    VStack(spacing: 16) { Image(systemName: "book.closed").font(.largeTitle); Text(book.title).font(.headline).multilineTextAlignment(.center).padding(.horizontal) }.foregroundColor(Color(red: 0.22, green: 0.36, blue: 0.28))
                }
            }.frame(height: 205)
            Text(book.title).font(.headline).lineLimit(2).foregroundColor(.primary)
            Text(book.author.isEmpty ? book.format.rawValue.uppercased() : book.author).font(.caption).foregroundColor(.secondary).lineLimit(1)
            if let position = book.position {
                ProgressView(value: position.progression)
                Text("\(Int(position.progression * 100))%" + (book.pendingSync ? " · 待同步" : "")).font(.caption2).foregroundColor(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
