import SwiftUI
import PDFKit
import ReadiumShared
import ReadiumNavigator

struct ContentsItem: Identifiable {
    let id = UUID()
    let title: String
    let link: ReadiumShared.Link?
    let pdfPage: Int?
}
struct SyncPrompt: Identifiable {
    enum Kind { case conflict, approximate }
    let id = UUID()
    let kind: Kind
    let remote: RemoteProgress
}
@MainActor final class ReaderSession: NSObject, ObservableObject, EPUBNavigatorDelegate {
    let bookID: UUID
    let container = ReaderContainerController()
    @Published var ready = false
    @Published var error: String?
    @Published var bridgeWarning: String?
    @Published var progression: Double = 0
    @Published var contents: [ContentsItem] = []
    @Published var prompt: SyncPrompt?
    private let store: LibraryStore
    private let readium: ReadiumService
    let sync: SyncCoordinator
    private var originalSpine: [String] = []
    private var progressionRanges: [String: ClosedRange<Double>] = [:]
    private var epub: EPUBNavigatorViewController?
    private var pdf: PDFView?
    private var pageObserver: NSObjectProtocol?
    private var saving: Task<Void, Never>?
    private var captureGeneration = 0
    private var suppressChanges = false
    private var loading = false
    private var busySync = false
    private var current: ReadingPosition?
    private var closed = false
    private var userHasMoved = false
    private var persistenceError: Error?

    init(bookID: UUID, store: LibraryStore, readium: ReadiumService, sync: SyncCoordinator) {
        self.bookID = bookID; self.store = store; self.readium = readium; self.sync = sync
        super.init()
        current = store.book(bookID)?.position; progression = current?.progression ?? 0
    }
    deinit { if let token = pageObserver { NotificationCenter.default.removeObserver(token) }; saving?.cancel() }
    var title: String { store.book(bookID)?.title ?? "阅读" }
    func load() async {
        guard !loading else { return }; loading = true
        do {
            guard var book = store.book(bookID) else { throw AppFailure("图书已删除") }
            book.lastOpenedAt = Date(); try store.save(book)
            suppressChanges = true
            switch book.format {
            case .epub:
                let publication = try await readium.open(store.fileURL(book.filePath))
                do { originalSpine = try await readium.spine(store.fileURL(book.filePath)) } catch { bridgeWarning = "无法读取原始章节顺序，EPUB 同步暂停。" }
                let positions = (try? await publication.positionsByReadingOrder().get()) ?? []
                let order = publication.readingOrder
                let starts = order.indices.map { index in
                    positions.indices.contains(index) ? (positions[index].first?.locations.totalProgression ?? Double(index) / Double(order.count)) : Double(index) / Double(order.count)
                }
                for index in order.indices {
                    let end = index + 1 < starts.count ? starts[index + 1] : 1
                    progressionRanges[EPUBPositionBridge.normalize(order[index].href)] = starts[index]...max(starts[index], end)
                }
                let locator = try book.position?.locatorJSON.flatMap { try Locator(jsonString: $0) }
                let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator, config: .init(preferences: preferences()))
                navigator.delegate = self; epub = navigator
                container.embed(navigator)
                func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [ContentsItem] {
                    links.flatMap { [ContentsItem(title: String(repeating: "  ", count: depth) + ($0.title ?? "章节"), link: $0, pdfPage: nil)] + flatten($0.children, depth: depth+1) }
                }
                contents = flatten(try await publication.tableOfContents().get())
            case .pdf:
                guard let document = PDFDocument(url: store.fileURL(book.filePath)), document.pageCount > 0 else { throw AppFailure("无法打开 PDF") }
                let view = PDFView(frame: container.view.bounds); view.document = document; view.autoScales = true
                view.displayMode = .singlePageContinuous; view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.view.addSubview(view); pdf = view
                if let page = book.position?.pdfPage, let target = document.page(at: min(max(page,0),document.pageCount-1)) { view.go(to: target) }
                if let outline = document.outlineRoot {
                    func flatten(_ item: PDFOutline, depth: Int = 0) -> [ContentsItem] {
                        (0..<item.numberOfChildren).flatMap { index -> [ContentsItem] in
                            guard let child = item.child(at: index) else { return [] }
                            let page = child.destination?.page.map { document.index(for: $0) }
                            return [ContentsItem(title: String(repeating: "  ", count: depth) + (child.label ?? "章节"), link: nil, pdfPage: page)] + flatten(child, depth: depth+1)
                        }
                    }
                    contents = flatten(outline)
                }
                if contents.isEmpty { contents = (0..<document.pageCount).map { ContentsItem(title: "第 \($0+1) 页", link: nil, pdfPage: $0) } }
                pageObserver = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.pdfChanged() }
                }
            }
            // Allow layout and the initial location event to finish before tracking user movement.
            try await Task.sleep(nanoseconds: 350_000_000)
            try await initialCheckpoint()
            ready = true
            suppressChanges = false
            await synchronize(flushFirst: false)
        } catch { self.error = error.localizedDescription; suppressChanges = false }
    }
    private func initialCheckpoint() async throws {
        guard var book = store.book(bookID) else { return }
        var position: ReadingPosition?
        if let navigator = epub {
            // WebKit cold starts can outlast the usual two-second chapter load.
            // Keep restoration events suppressed until the initial checkpoint is saved.
            for _ in 0..<100 {
                try Task.checkCancellation()
                if let location = navigator.currentLocation {
                    let locator = adjusted(location)
                    let pointer = try? await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: originalSpine)
                    guard let pointer = pointer else { try await Task.sleep(nanoseconds: 100_000_000); continue }
                    position = ReadingPosition(progression: locator.locations.totalProgression ?? 0, locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: current?.updatedAt ?? Date())
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } else if let document = pdf?.document, let page = pdf?.currentPage {
            let index = document.index(for: page)
            position = ReadingPosition(progression: Double(index+1)/Double(document.pageCount), pdfPage: index, updatedAt: current?.updatedAt ?? Date())
        }
        if let position = position {
            current = position; progression = position.progression; book.position = position
            // Opening/restoring a file is a checkpoint, never a new user edit.
            try store.save(book)
        }
    }
    private func preferences() -> EPUBPreferences {
        let settings = store.settings.reader
        return EPUBPreferences(columnCount: .one, fontSize: settings.fontSize / 100, publisherStyles: false, theme: settings.theme == "dark" ? .dark : settings.theme == "sepia" ? .sepia : .light)
    }
    private func adjusted(_ locator: Locator) -> Locator {
        guard let progression = locator.locations.progression,
              let range = progressionRanges[EPUBPositionBridge.normalize(locator.href.string)] else { return locator }
        let total = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(progression, 0), 1)
        return locator.copy(locations: { $0.totalProgression = total })
    }
    func updatePreferences() { epub?.submitPreferences(preferences()) }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { self.error = error.localizedDescription }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        let locator = adjusted(locator)
        progression = locator.locations.totalProgression ?? progression
        guard !suppressChanges, !closed else { return }
        if locator.jsonString == current?.locatorJSON { return }
        userHasMoved = true
        captureGeneration += 1
        let generation = captureGeneration
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self = self, generation == self.captureGeneration else { return }
            await self.captureEPUB(locator, generation: generation)
        }
    }
    private func captureEPUB(_ locator: Locator, generation: Int) async {
        let locator = adjusted(locator)
        guard let navigator = epub else { return }
        let pointer: String?
        do { pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: originalSpine); bridgeWarning = nil }
        catch { pointer = nil; bridgeWarning = "无法转换当前位置，已保留本地进度；同步上传暂停。" }
        guard generation == captureGeneration, !suppressChanges else { return }
        let position = ReadingPosition(progression: locator.locations.totalProgression ?? progression, locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date())
        saveChanged(position)
    }
    private func pdfChanged() {
        guard !suppressChanges, !closed, let view = pdf, let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index == current?.pdfPage { return }
        userHasMoved = true
        saveChanged(ReadingPosition(progression: Double(index+1) / Double(document.pageCount), pdfPage: index, updatedAt: Date()))
    }
    private func saveChanged(_ position: ReadingPosition) {
        guard var book = store.book(bookID) else { return }
        // Restoring an existing page should not create a dirty record.
        if book.position?.pdfPage == position.pdfPage && book.position?.locatorJSON == position.locatorJSON && book.position?.xpointer == position.xpointer { return }
        current = position; progression = position.progression; book.position = position; book.pendingSync = true
        do { try store.save(book); persistenceError = nil } catch { persistenceError = error; self.error = error.localizedDescription }
    }
    func flush() async {
        guard userHasMoved else { return }
        saving?.cancel(); captureGeneration += 1
        if let locator = epub?.currentLocation { await captureEPUB(locator, generation: captureGeneration) }
        else { pdfChanged() }
    }
    func close() async { await background(); closed = true }
    func background() async { await flush(); await synchronize(flushFirst: false) }
    func turn(forward: Bool) async {
        if let epub = epub { if forward { await epub.goForward() } else { await epub.goBackward() } }
        else if let pdf = pdf, let doc = pdf.document, let page = pdf.currentPage {
            let index = doc.index(for: page) + (forward ? 1 : -1)
            if let target = doc.page(at: index) { pdf.go(to: target) }
        }
    }
    func go(_ item: ContentsItem) async {
        if let link = item.link { await epub?.go(to: link) }
        if let page = item.pdfPage, let target = pdf?.document?.page(at: page) { pdf?.go(to: target) }
    }
    func synchronize(preferLocal: Bool = false, flushFirst: Bool = true) async {
        guard ready, !busySync, prompt == nil else { return }
        busySync = true; defer { busySync = false }
        do {
            // Save the latest page before the coordinator takes a snapshot.
            if flushFirst { await flush() }
            if let error = persistenceError { throw error }
            switch try await sync.synchronize(bookID, preferLocal: preferLocal) {
            case .idle: break
            case .conflict(let remote): prompt = SyncPrompt(kind: .conflict, remote: remote)
            case .remote(let remote): await receive(remote)
            }
        } catch { self.error = error.localizedDescription }
    }
    func receive(_ remote: RemoteProgress, approximate: Bool = false) async {
        suppressChanges = true; saving?.cancel(); captureGeneration += 1
        defer { suppressChanges = false }
        let previous = current
        epub?.view.isUserInteractionEnabled = false
        pdf?.isUserInteractionEnabled = false
        defer { epub?.view.isUserInteractionEnabled = true; pdf?.isUserInteractionEnabled = true }
        do {
            var position: ReadingPosition
            if let navigator = epub {
                let locator: Locator
                if approximate {
                    guard let percentage = remote.percentage, let target = await navigator.publication.locate(progression: percentage) else { throw AppFailure("无法按百分比定位") }
                    locator = target
                } else {
                    guard let pointer = remote.progress else { throw AppFailure("远端没有正文位置") }
                    locator = try await EPUBPositionBridge.locator(pointer: pointer, navigator: navigator, spine: originalSpine)
                }
                guard await navigator.go(to: locator) else { throw AppFailure("无法跳转到远端位置") }
                position = ReadingPosition(progression: remote.percentage ?? 0, locatorJSON: locator.jsonString, xpointer: approximate ? nil : remote.progress, updatedAt: Date())
            } else {
                guard let raw = remote.progress, let page = Int(raw), page > 0, let document = pdf?.document, let target = document.page(at: page-1) else { throw AppFailure("远端 PDF 页码不在本书范围内") }
                pdf?.go(to: target)
                position = ReadingPosition(progression: Double(page)/Double(document.pageCount), pdfPage: page-1, updatedAt: Date())
            }
            try sync.acceptRemote(remote, id: bookID, position: position)
            current = position; progression = position.progression; bridgeWarning = nil
            userHasMoved = false
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            // A failed conversion may have opened a different chapter. Restore before offering fallback.
            if let json = previous?.locatorJSON, let locator = try? Locator(jsonString: json) { await epub?.go(to: locator) }
            if epub != nil && !approximate { prompt = SyncPrompt(kind: .approximate, remote: remote) }
            else { self.error = error.localizedDescription }
        }
    }
}

@MainActor final class ReaderContainerController: UIViewController {
    private var appeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }
    override func viewWillDisappear(_ animated: Bool) {
        appeared = false
        super.viewWillDisappear(animated)
    }
    func embed(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        // UIKit forwards an in-flight parent appearance transition automatically.
        // Only start a separate transition when the parent has already appeared.
        if appeared { child.beginAppearanceTransition(true, animated: false) }
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
        view.setNeedsLayout(); view.layoutIfNeeded()
        if appeared { child.endAppearanceTransition() }
    }
}
