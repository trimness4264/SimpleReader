import SwiftUI
import PDFKit
import ReadiumShared
import ReadiumNavigator
import WebKit

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
@MainActor final class ReaderSession: NSObject, ObservableObject, EPUBNavigatorDelegate, ReaderPageTurnDelegate {
    let bookID: UUID
    let container = ReaderContainerController()
    @Published var ready = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var supportsScrolling = false
    @Published private(set) var isRestoring = false
    @Published private(set) var isNavigating = false
    @Published private(set) var canReturnToPreviousPosition = false
    @Published private(set) var recoveryError: String?
    @Published var error: String?
    @Published var bridgeWarning: String?
    @Published private(set) var syncMessage: String?
    @Published var progression: Double = 0
    @Published var contents: [ContentsItem] = []
    @Published private(set) var currentContentsID: UUID?
    @Published var prompt: SyncPrompt?
    private let store: LibraryStore
    private let readium: ReadiumService
    let sync: SyncCoordinator
    private var epubPosition: EPUBReadingPosition?
    private var epub: EPUBNavigatorViewController?
    private var continuous: ContinuousEPUBController?
    private var activeEPUB: EPUBReadingNavigator? {
        if let continuous = continuous { return continuous }
        return epub
    }
    private var pdf: PDFView?
    private var pdfControlsTap: PDFControlsTap?
    private var pageObserver: NSObjectProtocol?
    private var saving: Task<Void, Never>?
    private var captureGeneration = 0
    // Invalidates remote navigation immediately, before debounced persistence.
    private var navigationRevision = 0
    private var suppressChanges = false
    private var loading = false
    private var busySync = false
    private var current: ReadingPosition?
    private var closed = false
    private var userHasMoved = false
    private var persistenceError: Error?
    private var offeredApproximateFingerprint: String?
    private var displaysTwoPages = false
    private var latestLocator: Locator?
    private var capturedLocator: Locator?
    private struct Checkpoint {
        let position: ReadingPosition?
        let locator: Locator?
        let destination: PDFDestination?
    }
    private var checkpoint: Checkpoint?
    private var previousPosition: Checkpoint?
    private var navigationOrigin: Checkpoint?
    private var restoration: Task<Void, Never>?
    private var restorationRevision = 0
    private var isActive = true
    private var wasBackgrounded = false
    private var reloadNavigatorOnRecovery = false

    init(bookID: UUID, store: LibraryStore, readium: ReadiumService, sync: SyncCoordinator) {
        self.bookID = bookID; self.store = store; self.readium = readium; self.sync = sync
        super.init()
        container.onLayout = { [weak self] size, idiom in
            self?.updatePageLayout(size: size, idiom: idiom)
        }
        container.onLayoutWillChange = { [weak self] in self?.protectPosition() }
        container.onLayoutDidChange = { [weak self] in self?.scheduleRestoration() }
        container.onAppearanceChange = { [weak self] in
            guard let self = self, self.store.settings.reader.theme == "system" else { return }
            self.updatePreferences()
        }
        container.pageTurnDelegate = self
        current = store.book(bookID)?.position; progression = current?.progression ?? 0
    }
    deinit { if let token = pageObserver { NotificationCenter.default.removeObserver(token) }; saving?.cancel(); restoration?.cancel() }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
        EPUBPositionBridge.installMediaLayout(in: controller)
    }
    func toggleControls() {
        guard ready, !closed, !isRestoring, !container.isTurningPage else { return }
        controlsVisible.toggle()
    }
    func contentTapped(at point: CGPoint, in bounds: CGRect) {
        guard bounds.width > 0, bounds.contains(point), point.x >= bounds.minX + bounds.width * 0.2,
              point.x <= bounds.minX + bounds.width * 0.8 else { return }
        toggleControls()
    }
    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard let epub = epub, (navigator as AnyObject) === epub, epub.currentSelection == nil else { return }
        contentTapped(at: point, in: epub.view.bounds)
    }
    var title: String { store.book(bookID)?.title ?? "阅读" }
    var isScrolling: Bool { supportsScrolling && store.settings.reader.layout == .scroll }
    var pdfPageCount: Int? { pdf?.document?.pageCount }
    var currentPDFPage: Int? {
        guard let pdf = pdf, let document = pdf.document, let page = pdf.currentPage else { return nil }
        return document.index(for: page) + 1
    }
    var progressLabel: String {
        if let document = pdf?.document, let page = pdf?.currentPage {
            return "第 \(document.index(for: page) + 1) / \(document.pageCount) 页"
        }
        return "\(Int(min(max(progression, 0), 1) * 100))%"
    }

    /// Refresh the contents marker from the visible page without moving or saving it.
    func refreshContentsPosition() async {
        currentContentsID = nil
        if let document = pdf?.document, let page = pdf?.currentPage {
            let index = document.index(for: page)
            currentContentsID = contents.last(where: { ($0.pdfPage ?? Int.max) <= index })?.id
            return
        }
        guard let navigator = activeEPUB else { return }
        currentContentsID = await epubPosition?.contentsID(in: navigator, contents: contents)
    }
    func load() async {
        guard !loading else { return }; loading = true
        do {
            guard var book = store.book(bookID) else { throw AppFailure("图书已删除") }
            book.lastOpenedAt = Date(); try store.save(book)
            suppressChanges = true
            switch book.format {
            case .epub:
                let publication = try await readium.open(store.fileURL(book.filePath))
                let spine: [String]
                do { spine = try await readium.spine(store.fileURL(book.filePath)) }
                catch { spine = []; bridgeWarning = "无法读取原始章节顺序，EPUB 同步暂停。" }
                epubPosition = await EPUBReadingPosition(publication: publication, spine: spine)
                let locator = try book.position?.locatorJSON.flatMap { try Locator(jsonString: $0) }
                try installNavigator(publication: publication, locator: locator)
                func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [ContentsItem] {
                    links.flatMap { [ContentsItem(title: String(repeating: "  ", count: depth) + ($0.title ?? "章节"), link: $0, pdfPage: nil)] + flatten($0.children, depth: depth+1) }
                }
                contents = flatten(try await publication.tableOfContents().get())
            case .pdf:
                guard let document = PDFDocument(url: store.fileURL(book.filePath)), document.pageCount > 0 else { throw AppFailure("无法打开 PDF") }
                let view = PDFView(frame: container.view.bounds); view.document = document; view.autoScales = true
                view.displayMode = displaysTwoPages ? .twoUpContinuous : .singlePageContinuous
                view.displaysAsBook = false
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.view.addSubview(view); pdf = view
                pdfControlsTap = PDFControlsTap(view: view) { [weak self, weak view] point in
                    guard let view = view else { return }
                    self?.contentTapped(at: point, in: view.bounds)
                }
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
        if let navigator = activeEPUB, let epubPosition = epubPosition {
            position = try await epubPosition.initialPosition(in: navigator, updatedAt: current?.updatedAt ?? Date())
        } else if let view = pdf, let document = view.document {
            // PDFKit ignores page navigation before the reader has a viewport.
            // Keep the saved position intact until layout can restore it.
            for _ in 0..<50 {
                try Task.checkCancellation()
                if view.window != nil && !view.bounds.isEmpty { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !closed, view.window != nil, !view.bounds.isEmpty else {
                throw AppFailure("PDF 布局未就绪，请重新打开")
            }
            container.view.layoutIfNeeded()
            view.layoutIfNeeded()
            if let index = book.position?.pdfPage,
               let target = document.page(at: min(max(index, 0), document.pageCount - 1)) {
                view.go(to: target)
            }
            guard let page = view.currentPage else { throw AppFailure("无法恢复 PDF 阅读位置") }
            let index = document.index(for: page)
            position = ReadingPosition(progression: Double(index+1)/Double(document.pageCount), pdfPage: index, updatedAt: current?.updatedAt ?? Date())
        }
        if let position = position {
            current = position; progression = position.progression; book.position = position
            latestLocator = activeEPUB?.currentLocation.map(adjusted)
            capturedLocator = latestLocator
            // Opening/restoring a file is a checkpoint, never a new user edit.
            try store.save(book)
        }
    }
    private func preferences() -> EPUBPreferences {
        let settings = store.settings.reader
        let theme: Theme
        switch settings.theme {
        case "light": theme = .light
        case "dark": theme = .dark
        default: theme = container.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        }
        let twoPages = displaysTwoPages && !isScrolling
        return EPUBPreferences(columnCount: twoPages ? .two : .one,
            fontFamily: FontFamily(rawValue: settings.font.familyName), fontSize: settings.fontSize / 100,
            lineHeight: settings.lineHeight, pageMargins: settings.pageMargins,
            publisherStyles: false, scroll: false, spread: twoPages ? .always : .never, theme: theme)
    }
    private func updatePageLayout(size: CGSize, idiom: UIUserInterfaceIdiom) {
        let twoPages = ReaderPageLayout.displaysTwoPages(size: size, idiom: idiom)
        guard displaysTwoPages != twoPages else { return }
        displaysTwoPages = twoPages
        epub?.submitPreferences(preferences())
        if let pdf = pdf {
            let page = pdf.currentPage
            pdf.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
            pdf.autoScales = true
            if let page = page { pdf.go(to: page) }
        }
    }
    private func adjusted(_ locator: Locator) -> Locator { epubPosition?.adjusted(locator) ?? locator }
    func updatePreferences() {
        protectPosition()
        if let navigator = activeEPUB, isScrolling != (continuous != nil) {
            do { try installNavigator(publication: navigator.publication, locator: checkpoint?.locator ?? latestLocator) }
            catch { recoveryError = error.localizedDescription }
        } else {
            continuous?.updateSettings(store.settings.reader)
            epub?.submitPreferences(preferences())
        }
        scheduleRestoration()
    }
    private func installNavigator(publication: Publication, locator: Locator?) throws {
        supportsScrolling = publication.metadata.layout != .fixed
        epub?.delegate = nil
        continuous?.close()
        continuous = nil
        epub = nil
        if isScrolling {
            let navigator = ContinuousEPUBController(publication: publication, initialLocation: locator,
                settings: store.settings.reader)
            navigator.onLocationChanged = { [weak self] location in self?.locationChanged(location) }
            navigator.onError = { [weak self] error in self?.error = error.localizedDescription }
            navigator.onContentTap = { [weak self] in self?.toggleControls() }
            continuous = navigator
            container.replaceChild(with: navigator)
            return
        }
        let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator,
            config: .init(preferences: preferences(), fontFamilyDeclarations: try ReaderFonts.declarations()))
        navigator.delegate = self
        epub = navigator
        container.replaceChild(with: navigator)
    }
    private func protectPosition() {
        container.cancelPageTransition()
        guard ready, !closed else { return }
        restorationRevision += 1; restoration?.cancel()
        navigationRevision += 1
        saving?.cancel(); captureGeneration += 1
        if checkpoint == nil {
            if let origin = navigationOrigin {
                checkpoint = origin
            } else {
                // Preserve a turn whose debounced text capture has not finished yet.
                // Never sample the navigator after its viewport has started changing.
                savePendingLocation()
                checkpoint = Checkpoint(position: current, locator: latestLocator, destination: pdfCheckpointDestination())
            }
        }
        isRestoring = true
        container.view.isUserInteractionEnabled = false
    }
    private func savePendingLocation() {
        guard ready, !suppressChanges, !isRestoring, !isNavigating, !closed,
              let locator = latestLocator, locator.jsonString != capturedLocator?.jsonString else { return }
        // Persist the locator synchronously in case the process stops before text capture finishes.
        saveChanged(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
            locatorJSON: locator.jsonString, updatedAt: Date()))
    }
    private func pdfCheckpointDestination() -> PDFDestination? {
        guard let pdf = pdf, let index = current?.pdfPage, let page = pdf.document?.page(at: index) else {
            return pdf?.currentDestination
        }
        let bounds = page.bounds(for: pdf.displayBox)
        // PDFView.currentDestination can describe the viewport's lower edge on
        // iPad. Returning to that point would advance into the following page.
        var point = pdf.convert(CGPoint(x: pdf.bounds.minX, y: pdf.bounds.minY), to: page)
        point.x = min(max(point.x, bounds.minX), bounds.maxX)
        point.y = min(max(point.y, bounds.minY), bounds.maxY)
        return PDFDestination(page: page, at: point)
    }
    private func scheduleRestoration() {
        guard checkpoint != nil, isActive, !closed else { return }
        restorationRevision += 1; restoration?.cancel()
        let revision = restorationRevision
        restoration = Task { [weak self] in
            guard let self = self else { return }
            do {
                // Coalesce Split View resizing and the subsequent column preference change.
                try await Task.sleep(nanoseconds: 150_000_000)
                try await self.restorePosition(revision: revision)
            } catch is CancellationError {
                // Keep the checkpoint for the next foreground/layout completion.
            } catch {
                guard revision == self.restorationRevision, !self.closed else { return }
                self.recoveryError = error.localizedDescription
            }
        }
    }
    private func restorePosition(revision: Int) async throws {
        guard let checkpoint = checkpoint else { return }
        recoveryError = nil
        if let navigator = activeEPUB {
            if reloadNavigatorOnRecovery {
                try installNavigator(publication: navigator.publication, locator: checkpoint.locator)
            }
            guard let navigator = activeEPUB, let epubPosition = epubPosition, let location = checkpoint.locator else {
                throw AppFailure("无法读取上次阅读位置")
            }
            try await epubPosition.restore(location, pointer: checkpoint.position?.xpointer, in: navigator) {
                revision == self.restorationRevision && self.isActive && !self.closed
            }
        } else if let destination = checkpoint.destination, let pdf = pdf {
            pdf.layoutIfNeeded()
            pdf.go(to: destination)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard revision == restorationRevision, isActive, !closed else { throw CancellationError() }
        if let navigator = activeEPUB, let epubPosition = epubPosition, let locator = navigator.currentLocation,
           var position = checkpoint.position, position.xpointer == nil {
            do {
                position.xpointer = try await epubPosition.capture(locator, in: navigator)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                bridgeWarning = "无法转换当前位置，已保留本地进度；同步上传暂停。"
            }
            guard revision == restorationRevision, isActive, !closed else { throw CancellationError() }
            if position.xpointer != nil, var book = store.book(bookID) {
                book.position = position
                try store.save(book)
                current = position
            }
        }
        latestLocator = activeEPUB?.currentLocation.map(adjusted)
        capturedLocator = latestLocator
        userHasMoved = false
        progression = checkpoint.position?.progression ?? progression
        self.checkpoint = nil
        reloadNavigatorOnRecovery = false
        isRestoring = false
        container.view.isUserInteractionEnabled = true
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { self.error = error.localizedDescription }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locationChanged(locator)
    }
    func pageTurnDidFinish(committed: Bool, error: Error?) async {
        if let error = error { self.error = error.localizedDescription }
        guard !isRestoring, !closed else { return }
        if pdf != nil {
            if committed { pdfChanged() }
            return
        }
        guard let navigator = epub, let epubPosition = epubPosition else { return }
        let revision = restorationRevision
        if committed {
            do {
                let captured = try await epubPosition.settledPage(in: navigator)
                let locator = captured.locator
                let pointer = captured.pointer
                guard revision == restorationRevision, isActive, !isRestoring, !closed, epub === navigator else { return }
                saving?.cancel(); captureGeneration += 1; navigationRevision += 1
                latestLocator = locator; capturedLocator = locator; userHasMoved = true
                saveChanged(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date()))
            } catch {
                guard revision == restorationRevision, !isRestoring, !closed else { return }
                container.cancelPageTransition()
                self.error = error.localizedDescription
            }
        } else if userHasMoved, let pending = latestLocator, pending.jsonString != capturedLocator?.jsonString {
            captureGeneration += 1
            let generation = captureGeneration
            saving = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self = self, !Task.isCancelled else { return }
                await self.captureEPUB(pending, generation: generation)
            }
        }
    }
    private func locationChanged(_ locator: Locator) {
        guard !suppressChanges, !isRestoring, !isNavigating, !closed, !container.isTurningPage else { return }
        let locator = adjusted(locator)
        guard locator.jsonString != latestLocator?.jsonString else { return }
        latestLocator = locator
        progression = locator.locations.totalProgression ?? progression
        if locator.jsonString == current?.locatorJSON { return }
        userHasMoved = true
        navigationRevision += 1
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
        guard let navigator = activeEPUB, let epubPosition = epubPosition else { return }
        let pointer: String?
        do { pointer = try await epubPosition.capture(locator, in: navigator); bridgeWarning = nil }
        catch { pointer = nil; bridgeWarning = "无法转换当前位置，已保留本地进度；同步上传暂停。" }
        guard generation == captureGeneration, !suppressChanges, !isRestoring, !closed, !container.isTurningPage else { return }
        let position = ReadingPosition(progression: locator.locations.totalProgression ?? progression, locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date())
        saveChanged(position)
        capturedLocator = locator
    }
    private func pdfChanged() {
        guard !suppressChanges, !isRestoring, !isNavigating, !closed, let view = pdf, let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index == current?.pdfPage { return }
        userHasMoved = true
        navigationRevision += 1
        saveChanged(ReadingPosition(progression: Double(index+1) / Double(document.pageCount), pdfPage: index, updatedAt: Date()))
    }
    private func saveChanged(_ position: ReadingPosition) {
        guard var book = store.book(bookID) else { return }
        // Restoring an existing page should not create a dirty record.
        if book.position?.pdfPage == position.pdfPage && book.position?.locatorJSON == position.locatorJSON && book.position?.xpointer == position.xpointer { return }
        book.position = position; book.pendingSync = true
        do {
            try store.save(book)
            current = position; progression = position.progression
            persistenceError = nil
        } catch { persistenceError = error; self.error = error.localizedDescription }
    }
    func flush() async {
        guard userHasMoved, !isRestoring, !isNavigating, !closed else { return }
        saving?.cancel(); captureGeneration += 1
        if let locator = latestLocator ?? activeEPUB?.currentLocation { await captureEPUB(locator, generation: captureGeneration) }
        else { pdfChanged() }
    }
    func close() async {
        container.cancelPageTransition()
        await flush()
        closed = true
        continuous?.close()
        restorationRevision += 1; restoration?.cancel()
        await synchronize(flushFirst: false, applyRemote: false)
    }
    func resignActive() {
        guard !closed else { return }
        isActive = false
        container.cancelPageTransition()
        if isNavigating || (ready && suppressChanges) {
            // An interrupted navigation still needs to return to its original position.
            protectPosition()
        } else {
            // A live reader keeps its page when the app is merely interrupted.
            restorationRevision += 1; restoration?.cancel()
            navigationRevision += 1
            savePendingLocation()
        }
    }
    func background() async {
        guard !closed else { return }
        resignActive()
        wasBackgrounded = true
        await flush()
        await synchronize(flushFirst: false, applyRemote: false)
    }
    func foreground() async {
        guard !closed else { return }
        isActive = true
        let shouldSync = wasBackgrounded
        wasBackgrounded = false
        if checkpoint != nil {
            scheduleRestoration()
            await restoration?.value
        }
        if shouldSync && isActive && !isRestoring && !closed { await synchronize() }
    }
    func retryRecovery() async {
        guard !closed else { return }
        protectPosition()
        reloadNavigatorOnRecovery = true
        await foreground()
    }
    func turn(forward: Bool) async {
        let towardLeft = epub.map { forward == ($0.presentation.readingProgression == .ltr) } ?? forward
        await container.turnPage(towardLeft: towardLeft)
    }

    func canBeginPageTurn(isGesture: Bool) -> Bool {
        guard ready, isActive, !closed, !suppressChanges, !isRestoring, !isNavigating else { return false }
        if isGesture {
            guard let epub = epub else { return false }
            return epub.publication.metadata.layout != .fixed && !epub.settings.scroll && epub.currentSelection == nil
        }
        return epub != nil || pdf != nil
    }

    func pageTurnWillBegin() {
        navigationRevision += 1
        captureGeneration += 1
        saving?.cancel()
    }

    func movePage(towardLeft: Bool) async throws -> Bool {
        let revision = restorationRevision
        if let epub = epub {
            let forward = towardLeft == (epub.presentation.readingProgression == .ltr)
            let options = NavigatorGoOptions(animated: false)
            let moved = forward ? await epub.goForward(options: options) : await epub.goBackward(options: options)
            guard revision == restorationRevision, self.epub === epub, isActive, !closed, !isRestoring else {
                throw CancellationError()
            }
            return moved
        }
        if let pdf = pdf, let doc = pdf.document, let page = pdf.currentPage {
            let index = ReaderPageLayout.nextPDFPage(current: doc.index(for: page), forward: towardLeft, twoPages: displaysTwoPages)
            guard let target = doc.page(at: index) else { return false }
            pdf.go(to: target)
            return true
        }
        return false
    }

    func go(_ item: ContentsItem) async {
        if let link = item.link { await navigate(to: .link(link)) }
        else if let page = item.pdfPage { await jump(toPage: page + 1) }
    }
    func jump(toProgression value: Double) async {
        guard value.isFinite else { return }
        let value = min(max(value, 0), 1)
        if let count = pdfPageCount {
            await jump(toPage: Int((value * Double(max(count - 1, 0))).rounded()) + 1)
        } else {
            await navigate(to: .progression(value))
        }
    }
    func jump(toPage page: Int) async {
        guard let count = pdfPageCount, (1...count).contains(page) else {
            error = "页码不在本书范围内"
            return
        }
        guard page != currentPDFPage else { return }
        await navigate(to: .page(page - 1))
    }
    func returnToPreviousPosition() async {
        guard let previousPosition = previousPosition else { return }
        await navigate(to: .checkpoint(previousPosition), returning: true)
    }

    private enum NavigationTarget {
        case progression(Double), link(ReadiumShared.Link), page(Int), checkpoint(Checkpoint)
    }
    private func move(to target: NavigationTarget, revision: Int) async throws {
        func isCurrent() -> Bool {
            revision == restorationRevision && isActive && !isRestoring && !closed && !Task.isCancelled
        }
        if let navigator = activeEPUB, let epubPosition = epubPosition {
            switch target {
            case .progression(let value):
                _ = try await epubPosition.go(toProgression: value, in: navigator, isCurrent: isCurrent)
            case .link(let link):
                try await epubPosition.go(to: link, in: navigator, isCurrent: isCurrent)
            case .checkpoint(let saved):
                try await epubPosition.restore(saved.locator, pointer: saved.position?.xpointer, in: navigator, isCurrent: isCurrent)
            case .page:
                throw AppFailure("无法跳转到指定位置")
            }
        } else if let pdf = pdf {
            switch target {
            case .page(let index):
                guard let page = pdf.document?.page(at: index) else { throw AppFailure("页码不在本书范围内") }
                pdf.go(to: page)
            case .checkpoint(let saved):
                guard let destination = saved.destination else { throw AppFailure("无法返回原位置") }
                pdf.go(to: destination)
            default: throw AppFailure("无法跳转到指定位置")
            }
        }
    }
    private func navigate(to target: NavigationTarget, returning: Bool = false) async {
        guard ready, isActive, !closed, !suppressChanges, !isRestoring, !isNavigating,
              !container.isTurningPage else { return }
        isNavigating = true
        navigationRevision += 1
        saving?.cancel(); captureGeneration += 1
        let revision = restorationRevision
        let navigator = activeEPUB
        var origin = Checkpoint(position: current, locator: navigator?.currentLocation.map(adjusted) ?? latestLocator,
                                destination: pdfCheckpointDestination())
        navigationOrigin = origin
        container.view.isUserInteractionEnabled = false
        defer {
            navigationOrigin = nil
            isNavigating = false
            if !isRestoring && !closed { container.view.isUserInteractionEnabled = true }
        }
        func checkActive() throws {
            guard revision == restorationRevision, isActive, !isRestoring, !closed, !Task.isCancelled else {
                throw CancellationError()
            }
        }
        do {
            if let navigator = navigator, let epubPosition = epubPosition, let locator = origin.locator {
                let pointer = try? await epubPosition.capture(locator, in: navigator)
                try checkActive()
                origin = Checkpoint(position: ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: current?.updatedAt ?? Date()),
                    locator: locator, destination: nil)
                navigationOrigin = origin
            }
            try await move(to: target, revision: revision)
            try checkActive()
            if navigator == nil { try await Task.sleep(nanoseconds: 500_000_000) }
            try checkActive()
            if let navigator = navigator, let epubPosition = epubPosition, let locator = navigator.currentLocation.map(adjusted) {
                let pointer = try? await epubPosition.capture(locator, in: navigator)
                try checkActive()
                saveChanged(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date()))
                if let error = persistenceError { throw error }
                latestLocator = locator; capturedLocator = locator
                bridgeWarning = pointer == nil ? "无法转换当前位置，已保留本地进度；同步上传暂停。" : nil
            } else if let page = currentPDFPage, let count = pdfPageCount {
                saveChanged(ReadingPosition(progression: Double(page) / Double(count), pdfPage: page - 1, updatedAt: Date()))
                if let error = persistenceError { throw error }
            }
            userHasMoved = true
            previousPosition = returning ? nil : origin
            canReturnToPreviousPosition = previousPosition != nil
            navigationOrigin = nil
            await refreshContentsPosition()
        } catch is CancellationError {
            if revision == restorationRevision, isActive, !isRestoring, !closed {
                checkpoint = origin
                isRestoring = true
                scheduleRestoration()
            }
        } catch {
            if revision == restorationRevision, isActive, !closed, !isRestoring {
                do {
                    try await move(to: .checkpoint(origin), revision: revision)
                    try checkActive()
                } catch is CancellationError {
                    return
                } catch {
                    checkpoint = origin
                    isRestoring = true
                    recoveryError = "无法恢复跳转前的位置，请重试"
                    scheduleRestoration()
                    return
                }
                latestLocator = origin.locator
                progression = origin.position?.progression ?? progression
                self.error = error.localizedDescription
            }
        }
    }
    func synchronize(preferLocal: Bool = false, flushFirst: Bool = true, userInitiated: Bool = false, applyRemote: Bool = true) async {
        guard ready, !busySync, !suppressChanges, !isNavigating, (!isRestoring || !applyRemote), !container.isTurningPage, prompt == nil else { return }
        busySync = true; defer { busySync = false }
        let revision = navigationRevision
        syncMessage = nil
        do {
            // Save the latest page before the coordinator takes a snapshot.
            if flushFirst { await flush() }
            if let error = persistenceError { throw error }
            let outcome = try await sync.synchronize(bookID, preferLocal: preferLocal)
            switch outcome {
            case .idle: break
            case .conflict(let remote), .remote(let remote):
                // A network response must not override a turn made while awaiting it,
                // even if the 400 ms position capture has not reached the store yet.
                guard applyRemote, !closed, !Task.isCancelled, revision == navigationRevision else {
                    syncMessage = "已保留当前阅读位置，请稍后同步"
                    return
                }
                if case .conflict = outcome {
                    prompt = SyncPrompt(kind: .conflict, remote: remote)
                } else if !userInitiated && remote.fingerprint == offeredApproximateFingerprint {
                    syncMessage = "远端位置无法精确解析，已保留本地进度"
                } else {
                    await receive(remote)
                }
            }
        } catch { syncMessage = "同步失败：\(error.localizedDescription)" }
    }
    func receive(_ remote: RemoteProgress, approximate: Bool = false) async {
        guard ready, !closed, !suppressChanges, !isRestoring, !isNavigating else { return }
        let revision = restorationRevision
        syncMessage = nil
        suppressChanges = true; saving?.cancel(); captureGeneration += 1
        defer { suppressChanges = false }
        let previous = current
        container.view.isUserInteractionEnabled = false
        pdf?.isUserInteractionEnabled = false
        defer { container.view.isUserInteractionEnabled = true; pdf?.isUserInteractionEnabled = true }
        do {
            var position: ReadingPosition
            if let navigator = activeEPUB, let epubPosition = epubPosition {
                let locator: Locator
                let isCurrent = { revision == self.restorationRevision && !self.closed && !self.isRestoring }
                if approximate {
                    guard let percentage = remote.percentage else { throw AppFailure("无法按百分比定位") }
                    locator = try await epubPosition.go(toProgression: percentage, in: navigator, isCurrent: isCurrent)
                } else {
                    guard let pointer = remote.progress else { throw AppFailure("远端没有正文位置") }
                    locator = try await epubPosition.go(toPointer: pointer, in: navigator, isCurrent: isCurrent)
                }
                guard isCurrent() else { return }
                position = ReadingPosition(progression: remote.percentage ?? 0, locatorJSON: locator.jsonString, xpointer: approximate ? nil : remote.progress, updatedAt: Date())
            } else {
                guard let raw = remote.progress, let page = Int(raw), page > 0, let document = pdf?.document, let target = document.page(at: page-1) else { throw AppFailure("远端 PDF 页码不在本书范围内") }
                pdf?.go(to: target)
                position = ReadingPosition(progression: Double(page)/Double(document.pageCount), pdfPage: page-1, updatedAt: Date())
            }
            try sync.acceptRemote(remote, id: bookID, position: position)
            current = position; progression = position.progression; bridgeWarning = nil
            latestLocator = activeEPUB?.currentLocation.map(adjusted)
            capturedLocator = latestLocator
            userHasMoved = false
        } catch {
            guard revision == restorationRevision, !closed, !isRestoring else { return }
            // A failed conversion may have opened a different chapter. Restore before offering fallback.
            if let json = previous?.locatorJSON, let locator = try? Locator(jsonString: json),
               let navigator = activeEPUB, let epubPosition = epubPosition {
                try? await epubPosition.restore(locator, pointer: previous?.xpointer, in: navigator) {
                    revision == self.restorationRevision && !self.closed && !self.isRestoring
                }
            }
            syncMessage = "同步失败：\(error.localizedDescription)"
            if activeEPUB != nil && !approximate {
                offeredApproximateFingerprint = remote.fingerprint
                prompt = SyncPrompt(kind: .approximate, remote: remote)
            }
        }
    }
}

enum ReaderPageLayout {
    static func displaysTwoPages(size: CGSize, idiom: UIUserInterfaceIdiom) -> Bool {
        // Use the reader's viewport, so narrow Split View and Stage Manager windows
        // stay readable even when the physical iPad is in landscape orientation.
        idiom == .pad && size.width >= 700 && size.width > size.height && size.height > 0
    }
    static func nextPDFPage(current: Int, forward: Bool, twoPages: Bool) -> Int {
        // PDF displaysAsBook is false: spreads begin with zero-based pages 0, 2, 4.
        // Use that pair's start even when currentPage points to its right page.
        let start = twoPages ? current / 2 * 2 : current
        let step = twoPages ? 2 : 1
        return start + (forward ? step : -step)
    }
}

private enum ReaderFonts {
    static let latin = FontFamily(rawValue: ReaderFont.serif.familyName)
    static let cjk: FontFamily = "LXGW WenKai"

    static func declarations() throws -> [AnyHTMLFontFamilyDeclaration] {
        func face(_ name: String, style: CSSFontStyle = .normal, weight: CSSStandardFontWeight = .normal) throws -> CSSFontFace {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                  let file = FileURL(url: url) else {
                throw AppFailure("阅读字体缺失：\(name)")
            }
            return CSSFontFace(file: file, style: style, weight: .standard(weight))
        }

        // Latin first: WenKai also contains Latin glyphs, so reversing this stack
        // would prevent mixed-language books from using Source Serif for Western text.
        return [
            CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: ReaderFont.system.familyName),
                alternates: ["PingFang SC", "Hiragino Sans GB", .sansSerif]
            ).eraseToAnyHTMLFontFamilyDeclaration(),
            CSSFontFamilyDeclaration(
                fontFamily: latin,
                alternates: [cjk, .serif],
                fontFaces: [
                    try face("SourceSerif4-Regular"),
                    try face("SourceSerif4-It", style: .italic),
                    try face("SourceSerif4-Bold", weight: .bold),
                    try face("SourceSerif4-BoldIt", style: .italic, weight: .bold)
                ]
            ).eraseToAnyHTMLFontFamilyDeclaration(),
            CSSFontFamilyDeclaration(
                fontFamily: cjk,
                fontFaces: [try face("LXGWWenKai-Regular")]
            ).eraseToAnyHTMLFontFamilyDeclaration()
        ]
    }
}

@MainActor private final class PDFControlsTap: NSObject, UIGestureRecognizerDelegate {
    private weak var pdf: PDFView?
    private let onTap: (CGPoint) -> Void
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))

    init(view: PDFView, onTap: @escaping (CGPoint) -> Void) {
        pdf = view
        self.onTap = onTap
        super.init()
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let pdf = pdf, pdf.currentSelection == nil else { return }
        onTap(gesture.location(in: pdf))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let pdf = pdf, pdf.currentSelection == nil else { return false }
        let point = touch.location(in: pdf)
        guard point.x >= pdf.bounds.width * 0.2, point.x <= pdf.bounds.width * 0.8 else { return false }
        if let page = pdf.page(for: point, nearest: false), let annotation = page.annotation(at: pdf.convert(point, to: page)),
           annotation.type == PDFAnnotationSubtype.link.rawValue || annotation.type == PDFAnnotationSubtype.widget.rawValue { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let other = otherGestureRecognizer as? UITapGestureRecognizer, other.numberOfTapsRequired > 1,
              let pdf = pdf, other.view?.isDescendant(of: pdf) == true else { return false }
        return true
    }
}
