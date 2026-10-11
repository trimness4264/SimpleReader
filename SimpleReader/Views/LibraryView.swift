import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let environment: AppEnvironment
    @ObservedObject private var store: LibraryStore
    @ObservedObject private var downloads: DownloadManager
    @State private var importing = false
    @State private var busy = false
    @State private var importingFilename: String?
    @State private var importMessage: String?
    @State private var importedBook: Book?
    @State private var error: String?
    @State private var selected: Book?
    @State private var deleting: [Book] = []
    @State private var selecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var search = ""
    @State private var sort = LibrarySort.lastRead
    init(environment: AppEnvironment) {
        self.environment = environment; store = environment.store; downloads = environment.downloads
    }
    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var books: [Book] {
        return store.books.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.author.localizedStandardContains(query)
                || $0.originalFilename.localizedStandardContains(query)
        }.sorted { lhs, rhs in
            switch sort {
            case .lastRead: return (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
            case .added: return lhs.addedAt > rhs.addedAt
            case .title: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }
    private var continuingBooks: [Book] {
        Array(store.books.filter { $0.lastOpenedAt != nil && ($0.position?.progression ?? 0) < 1 }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }.prefix(3))
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
                                Button("打开阅读") { selected = book }.disabled(selecting)
                            }
                            Spacer()
                            Button("收起") { importMessage = nil; importedBook = nil }
                        }
                    }.padding().background(Color.accentColor.opacity(0.1)).cornerRadius(12)
                }
                if !selecting && query.isEmpty && !continuingBooks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("继续阅读").font(.title2.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(continuingBooks) { book in
                                    Button { selected = book } label: { ContinueReadingCard(book: book, root: store.root) }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("继续阅读《\(book.title)》")
                                }
                            }.padding(.vertical, 2)
                        }
                    }
                }
                if !store.books.isEmpty {
                    HStack {
                        Text(query.isEmpty ? "全部图书" : "搜索结果").font(.title2.bold())
                        Text("\(books.count)").foregroundColor(.secondary)
                        Spacer()
                        Menu {
                            Picker("排序", selection: $sort) {
                                ForEach(LibrarySort.allCases, id: \.self) { order in Text(order.rawValue).tag(order) }
                            }
                        } label: { Label("排序", systemImage: "arrow.up.arrow.down").font(.callout) }
                        .accessibilityValue(sort.rawValue)
                    }
                }
                if selecting {
                    HStack {
                        Text("已选择 \(selectedIDs.count) 本").foregroundColor(.secondary)
                        Spacer()
                        Button(selectedIDs.count == books.count && !books.isEmpty ? "取消全选" : "全选") {
                            selectedIDs = selectedIDs.count == books.count ? [] : Set(books.map(\.id))
                        }.disabled(books.isEmpty)
                    }
                }
                if books.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.system(size: 48)).foregroundColor(.secondary)
                        Text(store.books.isEmpty ? "书库里还没有图书" : "没有找到图书").font(.title3)
                        Text(store.books.isEmpty ? "导入 EPUB 或 PDF，也可以从在线书库下载。" : "试试书名、作者或文件名。").foregroundColor(.secondary).multilineTextAlignment(.center)
                        if store.books.isEmpty {
                            Button("导入图书") { importing = true }.buttonStyle(.borderedProminent).disabled(busy)
                        } else { Button("清除搜索") { search = "" } }
                    }.frame(maxWidth: .infinity).padding(.vertical, 70)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 200), spacing: 20)], alignment: .leading, spacing: 24) {
                    ForEach(books) { book in
                        bookButton(book)
                    }
                }
            }.padding(20)
        }
        .navigationTitle("书库")
        .searchable(text: $search, prompt: "书名、作者或文件名")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if selecting {
                    Button("完成") { finishSelection() }
                } else {
                    DownloadsToolbarButton(manager: downloads)
                    Button("选择") { selectedIDs.removeAll(); selecting = true }.disabled(books.isEmpty || busy)
                    if busy { ProgressView() }
                    else { Button { importing = true } label: { Image(systemName: "plus") }.accessibilityLabel("导入图书") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                Button(role: .destructive) { deleting = books.filter { selectedIDs.contains($0.id) } } label: {
                    Label("删除所选（\(selectedIDs.count)）", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(selectedIDs.isEmpty)
                .padding().background(.regularMaterial)
            }
        }
        .onChange(of: search) { _ in selectedIDs.removeAll() }
        .onChange(of: store.books.map(\.id)) { ids in
            selectedIDs.formIntersection(Set(ids))
            if books.isEmpty { finishSelection() }
            if let book = importedBook, !ids.contains(book.id) { importedBook = nil; importMessage = nil }
        }
        .sheet(isPresented: $importing) {
            DocumentImportPicker { files in
                importing = false
                Task { await importFiles(files) }
            }
        }
        .fullScreenCover(item: $selected) { book in ReaderView(bookID: book.id, environment: environment) }
        .alert("删除 \(deleting.count) 本图书？", isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), presenting: deleting) { booksToDelete in
            Button("取消", role: .cancel) { deleting = [] }
            Button("删除", role: .destructive) {
                // Use the presented value: iOS 15 can clear the binding before this action runs.
                do {
                    try store.delete(booksToDelete)
                    finishSelection()
                } catch { self.error = error.localizedDescription }
                deleting = []
            }
        } message: { _ in Text("移除本机文件和阅读记录，服务器上的图书会保留。") }
        .errorAlert($error)
    }
    private func finishSelection() {
        selecting = false
        selectedIDs.removeAll()
    }
    @ViewBuilder private func bookButton(_ book: Book) -> some View {
        let button = Button {
            if selecting {
                if !selectedIDs.insert(book.id).inserted { selectedIDs.remove(book.id) }
            } else { selected = book }
        } label: {
            BookTile(book: book, root: store.root)
                .overlay(alignment: .topTrailing) {
                    if selecting {
                        Image(systemName: selectedIDs.contains(book.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundColor(selectedIDs.contains(book.id) ? .accentColor : .secondary)
                            .padding(6).background(.regularMaterial, in: Circle()).padding(8)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.title)
        .accessibilityValue(selecting ? (selectedIDs.contains(book.id) ? "已选择" : "未选择") : "")
        .accessibilityHint(selecting ? "轻点切换选择状态" : "轻点打开阅读")
        if selecting { button }
        else { button.contextMenu { Button(role: .destructive) { deleting = [book] } label: { Label("删除图书", systemImage: "trash") } } }
    }
    @MainActor private func importFiles(_ files: [URL]) async {
        guard !busy, !files.isEmpty else { return }
        busy = true; importMessage = nil; importedBook = nil; search = ""
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
private enum LibrarySort: String, CaseIterable {
    case lastRead = "最近阅读"
    case added = "最近添加"
    case title = "书名"
}

private struct ContinueReadingCard: View {
    let book: Book
    let root: URL
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 14) {
            BookCover(book: book, root: root).frame(width: 70, height: 104)
            VStack(alignment: .leading, spacing: 8) {
                Text(book.title).font(.headline).lineLimit(2)
                if !book.author.isEmpty { Text(book.author).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                ProgressView(value: book.position?.progression ?? 0)
                Text("读到 \(Int((book.position?.progression ?? 0) * 100))%")
                    .font(.caption).foregroundColor(.secondary)
                Label("继续阅读", systemImage: "arrow.right").font(.callout).foregroundColor(.accentColor)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14).frame(width: typeSize.isAccessibilitySize ? 340 : 280)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct BookCover: View {
    let book: Book
    let root: URL
    var body: some View {
        ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.88, green: 0.9, blue: 0.85))
                if let path = book.coverPath, let image = UIImage(contentsOfFile: root.appendingPathComponent(path).path) {
                    Image(uiImage: image).resizable().scaledToFit().padding(4)
                } else {
                    VStack(spacing: 8) { Image(systemName: "book.closed").font(.title2); Text(book.title).font(.caption).lineLimit(3).multilineTextAlignment(.center).padding(.horizontal, 8) }.foregroundColor(Color(red: 0.22, green: 0.36, blue: 0.28))
                }
        }.accessibilityHidden(true)
    }
}

private struct BookTile: View {
    let book: Book
    let root: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BookCover(book: book, root: root).frame(height: 205)
            Text(book.title).font(.headline).lineLimit(2).foregroundColor(.primary)
            Text(book.author.isEmpty ? book.format.rawValue.uppercased() : book.author).font(.caption).foregroundColor(.secondary).lineLimit(1)
            if let position = book.position {
                ProgressView(value: position.progression)
                Text("\(Int(position.progression * 100))%" + (book.pendingSync ? " · 待同步" : "")).font(.caption2).foregroundColor(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
