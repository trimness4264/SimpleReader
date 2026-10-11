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
@MainActor final class ReaderSession: NSObject, ObservableObject, EPUBNavigatorDelegate {
    let bookID: UUID
    let container = ReaderContainerController()
    @Published var ready = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var supportsScrolling = false
    @Published private(set) var isRestoring = false
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
    private var originalSpine: [String] = []
    private var progressionRanges: [String: ClosedRange<Double>] = [:]
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
    private var turningPage = false
    private var latestLocator: Locator?
    private var capturedLocator: Locator?
    private struct Checkpoint {
        let position: ReadingPosition?
        let locator: Locator?
        let destination: PDFDestination?
    }
    private var checkpoint: Checkpoint?
    private var restoration: Task<Void, Never>?
    private var restorationRevision = 0
    private var isActive = true
    private var wasBackgrounded = false

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
        container.onPageTurnBegan = { [weak self] in
            guard let self = self else { return }
            self.navigationRevision += 1
            self.captureGeneration += 1
            self.saving?.cancel()
        }
        container.onPageTurnSettled = { [weak self] committed in
            await self?.pageGestureSettled(committed: committed)
        }
        container.onPageTurn = { [weak self] left in
            guard let self = self, let epub = self.epub else { return }
            let forward = left == (epub.presentation.readingProgression == .ltr)
            Task { await self.turn(forward: forward) }
        }
        current = store.book(bookID)?.position; progression = current?.progression ?? 0
    }
    deinit { if let token = pageObserver { NotificationCenter.default.removeObserver(token) }; saving?.cancel(); restoration?.cancel() }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
        EPUBPositionBridge.installMediaLayout(in: controller)
    }
    func toggleControls() {
        guard ready, !closed, !isRestoring, !turningPage else { return }
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
        guard let navigator = activeEPUB, let locator = navigator.currentLocation else { return }
        let href = EPUBPositionBridge.normalize(locator.href.string)
        let candidates = contents.filter { item in
            item.link.map { EPUBPositionBridge.normalize($0.href) == href } ?? false
        }
        // A chapter can span resources which have no separate contents entry.
        let order = navigator.publication.readingOrder.map { EPUBPositionBridge.normalize($0.href) }
        let precedingEntry: ContentsItem?
        if let resourceIndex = order.firstIndex(of: href) {
            precedingEntry = contents.last { item in
                guard let link = item.link,
                      let index = order.firstIndex(of: EPUBPositionBridge.normalize(link.href)) else { return false }
                return index < resourceIndex
            }
        } else {
            precedingEntry = nil
        }
        // The resource's first entry is a safe fallback when visible text is unavailable.
        currentContentsID = candidates.first?.id ?? precedingEntry?.id
        guard !candidates.isEmpty else { return }
        do {
            let pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: originalSpine.isEmpty ? nil : originalSpine)
            let fragments = candidates.map { item in
                item.link?.href.components(separatedBy: "#").dropFirst().joined(separator: "#") ?? ""
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: fragments), as: UTF8.self)
            let result = try await navigator.evaluateJavaScript("""
                (() => {
                    const location = SimpleReaderBridge.resolve(\(try EPUBPositionBridge.quoted(pointer)));
                    const element = document.querySelector(location.cssSelector);
                    if (!element) return -1;
                    const node = element.childNodes[location.textNodeIndex] || element;
                    const fragments = \(json);
                    let current = -1;
                    fragments.forEach((fragment, index) => {
                        if (!fragment) { current = index; return; }
                        let id = fragment;
                        try { id = decodeURIComponent(fragment); } catch (_) {}
                        const target = document.getElementById(id);
                        if (target && (target === node || target.contains(node) ||
                            (target.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING))) {
                            current = index;
                        }
                    });
                    return current;
                })()
                """).get()
            if let index = result as? Int, candidates.indices.contains(index) {
                currentContentsID = candidates[index].id
            } else if (result as? Int) == -1 {
                currentContentsID = precedingEntry?.id
            }
        } catch {
            // Keep the resource-level marker for image-only or unsupported EPUB content.
        }
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
        if let navigator = activeEPUB {
            // WebKit cold starts can outlast the usual two-second chapter load.
            // Keep restoration events suppressed until the initial checkpoint is saved.
            for _ in 0..<100 {
                try Task.checkCancellation()
                if let location = navigator.currentLocation {
                    let locator = adjusted(location)
                    let pointer: String?
                    do {
                        pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: originalSpine.isEmpty ? nil : originalSpine)
                    } catch {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    // Text, media elements, and empty chapter starts all have an XPointer.
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
    private func adjusted(_ locator: Locator) -> Locator {
        guard let progression = locator.locations.progression,
              let range = progressionRanges[EPUBPositionBridge.normalize(locator.href.string)] else { return locator }
        let total = range.lowerBound + (range.upperBound - range.lowerBound) * min(max(progression, 0), 1)
        return locator.copy(locations: { $0.totalProgression = total })
    }
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
            container.canTurnPage = { false }
            container.replaceChild(with: navigator)
            return
        }
        let navigator = try EPUBNavigatorViewController(publication: publication, initialLocation: locator,
            config: .init(preferences: preferences(), fontFamilyDeclarations: try ReaderFonts.declarations()))
        navigator.delegate = self
        epub = navigator
        container.replaceChild(with: navigator)
        container.canTurnPage = { [weak self, weak navigator] in
            guard let self = self, let navigator = navigator else { return false }
            return self.ready && !self.closed && self.isActive && !self.suppressChanges
                && !self.turningPage && !self.isRestoring && publication.metadata.layout != .fixed
                && !navigator.settings.scroll && navigator.currentSelection == nil
        }
    }
    private func protectPosition() {
        container.cancelPageTransition()
        guard ready, !closed else { return }
        restorationRevision += 1; restoration?.cancel()
        navigationRevision += 1
        saving?.cancel(); captureGeneration += 1
        if checkpoint == nil {
            // Preserve a turn whose debounced text capture has not finished yet.
            // Never sample the navigator after its viewport has started changing.
            if let locator = latestLocator, locator.jsonString != capturedLocator?.jsonString {
                saveChanged(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, updatedAt: Date()))
            }
            checkpoint = Checkpoint(position: current, locator: latestLocator, destination: pdfCheckpointDestination())
        }
        isRestoring = true
        container.view.isUserInteractionEnabled = false
    }
    private func pdfCheckpointDestination() -> PDFDestination? {
        guard let pdf = pdf, let index = current?.pdfPage, let page = pdf.document?.page(at: index) else {
            return pdf?.currentDestination
        }
        let bounds = page.bounds(for: pdf.displayBox)
        var point = CGPoint(x: bounds.minX, y: bounds.maxY)
        if let destination = pdf.currentDestination, destination.page === page {
            point.x = min(max(destination.point.x, bounds.minX), bounds.maxX)
            point.y = min(max(destination.point.y, bounds.minY), bounds.maxY)
        }
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
            if wasBackgrounded {
                try installNavigator(publication: navigator.publication, locator: checkpoint.locator)
            }
            guard let navigator = activeEPUB, let location = checkpoint.locator else {
                throw AppFailure("无法读取上次阅读位置")
            }
            var loaded = false
            for _ in 0..<50 {
                try Task.checkCancellation()
                if await navigator.go(to: location, options: .init(animated: false)) {
                    let result = await navigator.evaluateJavaScript("Boolean(document.body && document.readyState !== 'loading')")
                    if (try? result.get()) as? Bool == true { loaded = true; break }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard loaded else { throw AppFailure("正文恢复超时，请重试") }
            try Task.checkCancellation()
            if let pointer = checkpoint.position?.xpointer {
                let anchor = try await EPUBPositionBridge.locator(pointer: pointer, navigator: navigator, spine: originalSpine.isEmpty ? nil : originalSpine)
                try Task.checkCancellation()
                guard await navigator.go(to: anchor, options: .init(animated: false)) else {
                    throw AppFailure("无法恢复正文位置，请重试")
                }
            }
        } else if let destination = checkpoint.destination, let pdf = pdf {
            pdf.layoutIfNeeded()
            pdf.go(to: destination)
        }
        // Readium debounces scroll notifications for 300 ms, then polls idle
        // every 100 ms. Keep those final reflow callbacks out of persistence.
        try await Task.sleep(nanoseconds: 500_000_000)
        guard revision == restorationRevision, isActive, !closed else { throw CancellationError() }
        if let navigator = activeEPUB, let locator = navigator.currentLocation,
           var position = checkpoint.position, position.xpointer == nil {
            do {
                position.xpointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator,
                    spine: originalSpine.isEmpty ? nil : originalSpine)
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
        wasBackgrounded = false
        isRestoring = false
        container.view.isUserInteractionEnabled = true
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { self.error = error.localizedDescription }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locationChanged(locator)
    }
    private func pageGestureSettled(committed: Bool) async {
        guard let navigator = epub, !isRestoring, !closed else { return }
        let revision = restorationRevision
        if committed {
            guard let visible = await navigator.firstVisibleElementLocator() else {
                container.cancelPageTransition()
                error = "无法读取翻页后的位置，请重试。"
                return
            }
            do {
                // Readium's locator notification is debounced. Read the settled
                // DOM and save its text anchor before making the gesture idle.
                let value = try await navigator.evaluateJavaScript("Math.abs(window.scrollX) / document.scrollingElement.scrollWidth").get()
                guard let fraction = value as? Double else { throw AppFailure("无法读取翻页后的进度") }
                let locator = adjusted(visible.copy(locations: { $0.progression = min(max(fraction, 0), 1) }))
                let pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: originalSpine)
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
        guard !suppressChanges, !isRestoring, !closed, !container.isPageTurnGestureActive else { return }
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
        guard let navigator = activeEPUB else { return }
        let pointer: String?
        do { pointer = try await EPUBPositionBridge.capture(navigator: navigator, locator: locator, spine: originalSpine); bridgeWarning = nil }
        catch { pointer = nil; bridgeWarning = "无法转换当前位置，已保留本地进度；同步上传暂停。" }
        guard generation == captureGeneration, !suppressChanges, !isRestoring, !closed, !container.isPageTurnGestureActive else { return }
        let position = ReadingPosition(progression: locator.locations.totalProgression ?? progression, locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date())
        saveChanged(position)
        capturedLocator = locator
    }
    private func pdfChanged() {
        guard !suppressChanges, !isRestoring, !closed, let view = pdf, let document = view.document, let page = view.currentPage else { return }
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
        current = position; progression = position.progression; book.position = position; book.pendingSync = true
        do { try store.save(book); persistenceError = nil } catch { persistenceError = error; self.error = error.localizedDescription }
    }
    func flush() async {
        guard userHasMoved, !isRestoring, !closed else { return }
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
        isActive = false
        protectPosition()
    }
    func background() async {
        guard !closed else { return }
        resignActive()
        wasBackgrounded = true
        await synchronize(flushFirst: false, applyRemote: false)
    }
    func foreground() async {
        guard !closed else { return }
        isActive = true
        let shouldSync = wasBackgrounded
        scheduleRestoration()
        await restoration?.value
        if shouldSync && !isRestoring && !closed { await synchronize() }
    }
    func retryRecovery() async {
        guard !closed else { return }
        wasBackgrounded = true
        await foreground()
    }
    func turn(forward: Bool) async {
        guard ready, !closed, !suppressChanges, !isRestoring, !turningPage else { return }
        turningPage = true
        defer { turningPage = false }
        navigationRevision += 1
        let revision = restorationRevision
        if let epub = epub {
            let direction: CGFloat = forward == (epub.presentation.readingProgression == .ltr) ? 1 : -1
            await container.animatePageTurn(direction: direction) {
                let options = NavigatorGoOptions(animated: false)
                let moved = forward ? await epub.goForward(options: options) : await epub.goBackward(options: options)
                guard moved, self.restorationRevision == revision, self.epub === epub,
                      self.isActive, !self.closed, !self.isRestoring else { return false }
                do {
                    _ = try await epub.evaluateJavaScript("document.readyState").get()
                    guard self.restorationRevision == revision, self.isActive, !self.closed, !self.isRestoring else { return false }
                    try await self.container.waitForEPUBContent()
                    return true
                } catch is CancellationError {
                    return false
                } catch {
                    self.error = error.localizedDescription
                    return false
                }
            }
        }
        else if let pdf = pdf, let doc = pdf.document, let page = pdf.currentPage {
            let index = ReaderPageLayout.nextPDFPage(current: doc.index(for: page), forward: forward, twoPages: displaysTwoPages)
            guard let target = doc.page(at: index) else { return }
            await container.animatePageTurn(direction: forward ? 1 : -1) {
                pdf.go(to: target)
                return true
            }
        }
    }
    func go(_ item: ContentsItem) async {
        guard ready, !closed, !suppressChanges, !isRestoring else { return }
        navigationRevision += 1
        if let link = item.link { _ = await activeEPUB?.go(to: link) }
        if let page = item.pdfPage, let target = pdf?.document?.page(at: page) { pdf?.go(to: target) }
    }
    func synchronize(preferLocal: Bool = false, flushFirst: Bool = true, userInitiated: Bool = false, applyRemote: Bool = true) async {
        guard ready, !busySync, !suppressChanges, (!isRestoring || !applyRemote), !turningPage, !container.isPageTurnGestureActive, prompt == nil else { return }
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
        guard ready, !closed, !suppressChanges, !isRestoring else { return }
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
            if let navigator = activeEPUB {
                let locator: Locator
                if approximate {
                    guard let percentage = remote.percentage, let target = await navigator.publication.locate(progression: percentage) else { throw AppFailure("无法按百分比定位") }
                    locator = target
                } else {
                    guard let pointer = remote.progress else { throw AppFailure("远端没有正文位置") }
                    locator = try await EPUBPositionBridge.locator(pointer: pointer, navigator: navigator, spine: originalSpine)
                }
                guard revision == restorationRevision, !closed, !isRestoring else { return }
                guard await navigator.go(to: locator) else { throw AppFailure("无法跳转到远端位置") }
                guard revision == restorationRevision, !closed, !isRestoring else { return }
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
            try await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            guard revision == restorationRevision, !closed, !isRestoring else { return }
            // A failed conversion may have opened a different chapter. Restore before offering fallback.
            if let json = previous?.locatorJSON, let locator = try? Locator(jsonString: json) { _ = await activeEPUB?.go(to: locator) }
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

private final class ReaderContainerView: UIView {
    var onSizeWillChange: (() -> Void)?

    override var frame: CGRect {
        willSet {
            if frame.size != newValue.size { onSizeWillChange?() }
        }
    }

    override var bounds: CGRect {
        willSet {
            if bounds.size != newValue.size { onSizeWillChange?() }
        }
    }
}

@MainActor final class ReaderContainerController: UIViewController, UIGestureRecognizerDelegate {
    private var appeared = false
    private var layoutSize: CGSize = .zero
    private var layoutChanged = false
    private var transitioning = false
    private var pageTransitionRevision = 0
    private var pageAnimator: UIViewPropertyAnimator?
    private var pageSnapshot: UIView?
    private var pageContent: UIView?
    private var committedPreview = false
    private struct PageDrag {
        let webView: WKWebView
        let pageOrigin: CGPoint
        let chapterScroll: UIScrollView?
        let chapterOrigin: CGPoint
        var scroll: UIScrollView?
        var origin: CGPoint
        var destination: CGPoint
        var crossesChapter = false
    }
    private var pageDrag: PageDrag?
    private let registeredPans = NSHashTable<UIPanGestureRecognizer>.weakObjects()
    var onLayout: ((CGSize, UIUserInterfaceIdiom) -> Void)?
    var onLayoutWillChange: (() -> Void)?
    var onLayoutDidChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var canTurnPage: (() -> Bool)?
    var onPageTurnBegan: (() -> Void)?
    var onPageTurnSettled: ((Bool) async -> Void)?
    var onPageTurn: ((Bool) -> Void)?
    private(set) var isPageTurnGestureActive = false
    private lazy var pageTurnPan = UIPanGestureRecognizer(target: self, action: #selector(handlePageTurn(_:)))

    override func loadView() {
        let surface = ReaderContainerView()
        surface.onSizeWillChange = { [weak self] in
            self?.layoutChanged = true
            self?.onLayoutWillChange?()
        }
        view = surface
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        if #available(iOS 17.0, *) {
            registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: ReaderContainerController, _: UITraitCollection) in
                controller.onAppearanceChange?()
            }
        }
        pageTurnPan.maximumNumberOfTouches = 1
        pageTurnPan.delegate = self
        view.addGestureRecognizer(pageTurnPan)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if #unavailable(iOS 17.0), previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            onAppearanceChange?()
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pageTurnPan && beginPageTurn(translation: pageTurnPan.translation(in: view))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pageTurnPan, canTurnPage?() == true else { return false }
        if let content = children.first?.view { registerPagePans(in: content) }
        return true
    }

    private func registerPagePans(in content: UIView) {
        if let scroll = content as? UIScrollView {
            let pan = scroll.panGestureRecognizer
            if !registeredPans.contains(pan) {
                registeredPans.add(pan)
                pan.require(toFail: pageTurnPan)
            }
        }
        for child in content.subviews { registerPagePans(in: child) }
    }

    func beginPageTurn(translation: CGPoint) -> Bool {
        guard pageSnapshot == nil, canTurnPage?() == true, abs(translation.x) > abs(translation.y) else { return false }
        isPageTurnGestureActive = true
        // Readium reports location only after scrolling settles. Invalidate an
        // in-flight sync now, before it can restore a distant remote position.
        onPageTurnBegan?()
        if let web = visibleWebView(in: children.first?.view ?? view) {
            var ancestor = web.superview
            var chapter: UIScrollView?
            while let parent = ancestor, parent !== view {
                if let scroll = parent as? UIScrollView { chapter = scroll; break }
                ancestor = parent.superview
            }
            let origin = web.scrollView.contentOffset
            pageDrag = PageDrag(webView: web, pageOrigin: origin, chapterScroll: chapter,
                                chapterOrigin: chapter?.contentOffset ?? .zero,
                                origin: origin, destination: origin)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    @objc func handlePageTurn(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            updatePageTurn(translation: gesture.translation(in: view))
        case .ended:
            finishPageTurn(translation: gesture.translation(in: view), velocity: gesture.velocity(in: view))
        case .cancelled, .failed:
            finishPageTurn(translation: .zero)
        default:
            break
        }
    }

    func finishPageTurn(translation: CGPoint, velocity: CGPoint = .zero) {
        let projected = translation.x + velocity.x * 0.12
        let crossedThreshold = abs(projected) >= max(32, view.bounds.width * 0.2)
        let quickSwipe = abs(translation.x) >= 8 && abs(velocity.x) >= 450
        let commit = translation.x * projected > 0 && (crossedThreshold || quickSwipe)
        updatePageTurn(translation: translation)
        guard let drag = pageDrag else {
            isPageTurnGestureActive = false
            if commit { onPageTurn?(projected < 0) }
            return
        }
        let revision = pageTransitionRevision
        Task { [weak self] in
            guard let self = self else { return }
            let target = commit ? drag.destination : drag.origin
            await self.settlePageDrag(drag, target: target, velocity: velocity.x)
            guard revision == self.pageTransitionRevision else { return }
            if commit, drag.scroll != nil, drag.crossesChapter,
               let content = self.children.first?.view,
               let snapshot = content.snapshotView(afterScreenUpdates: false) {
                snapshot.frame = content.convert(content.bounds, to: self.view)
                snapshot.isUserInteractionEnabled = true
                self.view.addSubview(snapshot)
                self.pageSnapshot = snapshot
                self.pageContent = content
                self.committedPreview = true
                drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
            }
            if commit && (drag.crossesChapter || drag.scroll == nil && drag.destination != drag.origin) {
                self.pageDrag = nil
                self.isPageTurnGestureActive = false
                self.onPageTurn?(projected < 0)
            } else {
                await self.onPageTurnSettled?(commit && drag.scroll != nil)
                guard revision == self.pageTransitionRevision else { return }
                self.pageDrag = nil
                self.isPageTurnGestureActive = false
            }
        }
    }

    func updatePageTurn(translation: CGPoint) {
        guard var drag = pageDrag else { return }
        let direction: CGFloat = translation.x < 0 ? 1 : -1
        let page = drag.webView.scrollView
        let destination = CGPoint(x: drag.pageOrigin.x + direction * page.bounds.width, y: drag.pageOrigin.y)
        page.setContentOffset(drag.pageOrigin, animated: false)
        drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        pageContent?.transform = .identity
        if canDisplay(offset: destination, in: page) {
            drag.scroll = page
            drag.origin = drag.pageOrigin
            drag.destination = destination
            drag.crossesChapter = false
        } else if let chapter = drag.chapterScroll {
            let next = CGPoint(x: drag.chapterOrigin.x + direction * chapter.bounds.width, y: drag.chapterOrigin.y)
            drag.scroll = canDisplay(offset: next, in: chapter) && hasLoadedChapter(at: next, in: chapter) ? chapter : nil
            drag.origin = drag.chapterOrigin
            drag.destination = canDisplay(offset: next, in: chapter) ? next : drag.origin
            drag.crossesChapter = drag.scroll != nil
        } else {
            drag.scroll = nil
            drag.origin = drag.pageOrigin
            drag.destination = drag.origin
        }
        if let scroll = drag.scroll {
            let width = scroll.bounds.width
            let distance = min(abs(translation.x), width)
            scroll.setContentOffset(CGPoint(x: drag.origin.x + direction * distance, y: drag.origin.y), animated: false)
        } else if let content = children.first?.view, !UIAccessibility.isReduceMotionEnabled {
            pageContent = content
            let resistance = translation.x / (1 + abs(translation.x) / 36)
            content.transform = CGAffineTransform(translationX: resistance, y: 0)
        }
        pageDrag = drag
    }

    private func canDisplay(offset: CGPoint, in scroll: UIScrollView) -> Bool {
        offset.x >= -scroll.adjustedContentInset.left - 1
            && offset.x <= scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right + 1
    }

    private func visibleWebView(in content: UIView) -> WKWebView? {
        guard !content.isHidden, content.alpha > 0.99 else { return nil }
        if let web = content as? WKWebView {
            let visible = web.convert(web.bounds, to: view).intersection(view.bounds)
            return visible.width > view.bounds.width / 2 && visible.height > view.bounds.height / 2 ? web : nil
        }
        return content.subviews.lazy.compactMap { self.visibleWebView(in: $0) }.first
    }

    private func hasLoadedChapter(at offset: CGPoint, in scroll: UIScrollView) -> Bool {
        let target = CGRect(origin: offset, size: scroll.bounds.size)
        func loaded(in content: UIView) -> Bool {
            guard !content.isHidden, content.alpha > 0.99 else { return false }
            if let web = content as? WKWebView {
                let overlap = web.convert(web.bounds, to: scroll).intersection(target)
                return overlap.width > target.width / 2 && web.scrollView.alpha > 0.99 && !web.isLoading
            }
            return content.subviews.contains { loaded(in: $0) }
        }
        return scroll.subviews.contains { loaded(in: $0) }
    }

    private func settlePageDrag(_ drag: PageDrag, target: CGPoint, velocity: CGFloat) async {
        let distance = abs((drag.scroll?.contentOffset.x ?? drag.origin.x) - target.x)
        let duration = min(0.4, max(0.16, distance / max(abs(velocity), 900)))
        let remaining = max(distance, 1)
        let initialSlope = min(2, abs(velocity) * duration / remaining)
        let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.2, y: initialSlope * 0.2), controlPoint2: CGPoint(x: 0.36, y: 1))
        let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, timingParameters: timing)
        pageAnimator = animator
        animator.addAnimations {
            drag.scroll?.contentOffset = target
            self.pageContent?.transform = .identity
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animator.addCompletion { _ in continuation.resume() }
            animator.startAnimation()
        }
        if pageAnimator === animator { pageAnimator = nil }
    }

    func cancelPageTransition() {
        pageTransitionRevision += 1
        let animator = pageAnimator
        pageAnimator = nil
        if animator?.state == .active {
            animator?.stopAnimation(false)
            animator?.finishAnimation(at: .current)
        }
        pageSnapshot?.removeFromSuperview()
        pageContent?.transform = .identity
        if let drag = pageDrag {
            drag.webView.scrollView.setContentOffset(drag.pageOrigin, animated: false)
            drag.chapterScroll?.setContentOffset(drag.chapterOrigin, animated: false)
        }
        pageDrag = nil
        isPageTurnGestureActive = false
        committedPreview = false
        pageSnapshot = nil
        pageContent = nil
    }

    func waitForEPUBContent() async throws {
        let revision = pageTransitionRevision
        // Readium resumes navigation before unhiding a cold chapter's scroll view.
        // Observe UIKit visibility instead of guessing a rendering delay.
        for _ in 0..<120 {
            guard revision == pageTransitionRevision, view.window != nil else { throw CancellationError() }
            if children.first.map({ hasVisibleEPUBContent(in: $0.view) }) == true { return }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        throw NSError(domain: "Reader", code: 1, userInfo: [NSLocalizedDescriptionKey: "章节内容尚未显示，请重试。"])
    }

    private func hasVisibleEPUBContent(in content: UIView) -> Bool {
        guard !content.isHidden, content.alpha > 0.99 else { return false }
        if let webView = content as? WKWebView {
            let visible = webView.convert(webView.bounds, to: view).intersection(view.bounds)
            return visible.width > view.bounds.width / 2 && visible.height > view.bounds.height / 2
                && webView.scrollView.alpha > 0.99
        }
        return content.subviews.contains { hasVisibleEPUBContent(in: $0) }
    }

    func animatePageTurn(direction: CGFloat, navigate: () async -> Bool) async {
        if committedPreview {
            let revision = pageTransitionRevision
            defer { if revision == pageTransitionRevision { cancelPageTransition() } }
            _ = await navigate()
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled,
              let content = children.first?.view ?? view.subviews.first(where: { $0 is PDFView }),
              view.window != nil, view.bounds.width > 0,
              let snapshot = content.snapshotView(afterScreenUpdates: false) else {
            _ = await navigate()
            return
        }
        cancelPageTransition()
        let revision = pageTransitionRevision
        let size = view.bounds.size
        snapshot.frame = content.convert(content.bounds, to: view)
        snapshot.isUserInteractionEnabled = true
        view.addSubview(snapshot)
        pageSnapshot = snapshot
        pageContent = content
        defer {
            if revision == pageTransitionRevision { cancelPageTransition() }
            snapshot.removeFromSuperview()
        }

        // Navigation owns chapter loading and locators; animate only our views
        // once Readium has finished its non-animated navigation.
        let moved = await navigate()
        guard moved, revision == pageTransitionRevision, content.superview === view,
              view.window != nil, view.bounds.size == size else { return }
        view.layoutIfNeeded()
        guard revision == pageTransitionRevision else { return }
        let offset = CGAffineTransform(translationX: direction * size.width, y: 0)
        content.transform = offset
        let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.22, y: 1), controlPoint2: CGPoint(x: 0.36, y: 1))
        let animator = UIViewPropertyAnimator(duration: 0.28, timingParameters: timing)
        pageAnimator = animator
        animator.addAnimations {
            content.transform = .identity
            snapshot.transform = offset.inverted()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            animator.addCompletion { _ in continuation.resume() }
            animator.startAnimation()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        transitioning = true
        onLayoutWillChange?()
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.transitioning = false
            self?.onLayoutDidChange?()
        }
    }

    override func viewWillLayoutSubviews() {
        if layoutSize != view.bounds.size {
            layoutSize = view.bounds.size
            layoutChanged = true
        }
        super.viewWillLayoutSubviews()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?(view.bounds.size, traitCollection.userInterfaceIdiom)
        if layoutChanged && !transitioning { onLayoutDidChange?() }
        layoutChanged = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
    }
    override func viewWillDisappear(_ animated: Bool) {
        cancelPageTransition()
        appeared = false
        super.viewWillDisappear(animated)
    }
    func replaceChild(with child: UIViewController) {
        cancelPageTransition()
        registeredPans.removeAllObjects()
        for previous in children {
            previous.willMove(toParent: nil)
            if appeared { previous.beginAppearanceTransition(false, animated: false) }
            previous.view.removeFromSuperview()
            if appeared { previous.endAppearanceTransition() }
            previous.removeFromParent()
        }
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
