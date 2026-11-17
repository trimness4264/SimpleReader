import SwiftUI
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
    let revision: Int
}
@MainActor final class ReaderSession: NSObject, ObservableObject, EPUBNavigatorDelegate, ReaderPageTurnDelegate {
    let bookID: UUID
    let container = ReaderContainerController()
    @Published private(set) var ready = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var supportsScrolling = false
    @Published private(set) var isRestoring = false
    @Published private(set) var isNavigating = false
    @Published private(set) var canReturnToPreviousPosition = false
    @Published private(set) var recoveryError: String?
    @Published var error: String?
    @Published var bridgeWarning: String?
    @Published private var syncNotice: String?
    @Published private(set) var syncError: String?
    var syncMessage: String? { syncError ?? syncNotice }
    @Published var progression: Double = 0
    @Published var contents: [ContentsItem] = []
    @Published private(set) var currentContentsID: UUID?
    @Published var prompt: SyncPrompt?
    private let store: LibraryStore
    private let readium: ReadiumService
    let sync: SyncCoordinator
    private let positions: ReaderPositionSession
    private var epubPosition: EPUBReadingPosition?
    private var epub: EPUBNavigatorViewController?
    private var continuous: ContinuousEPUBController?
    private var activeEPUB: EPUBReadingNavigator? {
        if let continuous = continuous { return continuous }
        return epub
    }
    private var pdf: PDFReader?
    private var pdfPageTurnOrigin: (revision: Int, reader: PDFReader, checkpoint: Checkpoint)?
    private var scrollInsets: UIEdgeInsets?
    private var loading = false
    private var busySync = false
    private var closed = false
    private var offeredApproximateFingerprint: String?
    private var displaysTwoPages = false
    private var isActive = true
    private var wasBackgrounded = false
    private var reloadNavigatorOnRecovery = false
    private typealias Checkpoint = ReaderPositionSession.Checkpoint

    init(bookID: UUID, store: LibraryStore, readium: ReadiumService, sync: SyncCoordinator) {
        self.bookID = bookID; self.store = store; self.readium = readium; self.sync = sync
        positions = ReaderPositionSession(bookID: bookID, store: store, sync: sync)
        super.init()
        progression = positions.current?.progression ?? 0
        positions.onActivityChanged = { [weak self] activity in
            guard let self = self else { return }
            self.isRestoring = activity == .restoring
            self.isNavigating = activity == .navigating
            self.container.view.isUserInteractionEnabled = activity == .idle && !self.closed
        }
        container.onLayout = { [weak self] size, idiom in
            self?.updatePageLayout(size: size, idiom: idiom)
        }
        container.onLayoutWillChange = { [weak self] in self?.protectPosition() }
        container.onLayoutDidChange = { [weak self] in self?.scheduleRestoration() }
        container.onAppearanceChange = { [weak self] in
            guard let self = self, self.store.settings.reader.theme == .system else { return }
            self.updatePreferences()
        }
        container.pageTurnDelegate = self
    }
    func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts controller: WKUserContentController) {
        EPUBPositionBridge.installMediaLayout(in: controller)
    }
    func toggleControls() {
        guard ready, !closed, positions.activity == .idle, !container.isTurningPage else { return }
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
    var title: String { store.book(bookID)?.title ?? String(localized: "Reading") }
    var isScrolling: Bool { supportsScrolling && store.settings.reader.layout == .scroll }
    var pdfPageCount: Int? { pdf?.pageCount }
    var currentPDFPage: Int? { pdf?.page.map { $0 + 1 } }
    var progressLabel: String {
        if let count = pdfPageCount, let page = currentPDFPage {
            return String(localized: "Page \(page) of \(count)")
        }
        return "\(Int(min(max(progression, 0), 1) * 100))%"
    }

    /// Refresh the contents marker from the visible page without moving or saving it.
    func refreshContentsPosition() async {
        currentContentsID = nil
        if let index = pdf?.page {
            currentContentsID = contents.last(where: { ($0.pdfPage ?? Int.max) <= index })?.id
            return
        }
        guard let navigator = activeEPUB else { return }
        let revision = positions.revision
        let contentsID = await epubPosition?.contentsID(in: navigator, contents: contents)
        guard positions.isCurrent(revision), activeEPUB === navigator, !closed else { return }
        currentContentsID = contentsID
    }
    func load() async {
        guard !loading else { return }; loading = true
        do {
            guard var book = store.book(bookID) else { throw AppFailure("The book has been deleted.") }
            book.lastOpenedAt = Date(); try store.save(book)
            switch book.format {
            case .epub:
                let publication = try await readium.open(store.fileURL(book.filePath))
                let spine: [String]
                do { spine = try await readium.spine(store.fileURL(book.filePath)) }
                catch { spine = []; bridgeWarning = String(localized: "Couldn’t read the original chapter order. EPUB sync is paused.") }
                epubPosition = await EPUBReadingPosition(publication: publication, spine: spine)
                guard !closed else { return }
                try Task.checkCancellation()
                let locator = try book.position?.locatorJSON.flatMap { try Locator(jsonString: $0) }
                try installNavigator(publication: publication, locator: locator)
                func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [ContentsItem] {
                    links.flatMap { [ContentsItem(title: String(repeating: "  ", count: depth) + ($0.title ?? String(localized: "Chapter")), link: $0, pdfPage: nil)] + flatten($0.children, depth: depth+1) }
                }
                contents = flatten(try await publication.tableOfContents().get())
            case .pdf:
                let reader = try PDFReader(url: store.fileURL(book.filePath), in: container.view,
                    twoPages: displaysTwoPages, insets: scrollInsets) { [weak self] point, bounds in
                    self?.contentTapped(at: point, in: bounds)
                }
                reader.onMovementBegan = { [weak self] in self?.positions.movementBegan() }
                reader.onPageChanged = { [weak self] position in
                    guard let self = self, !self.container.isTurningPage else { return }
                    self.pdfChanged(position)
                }
                pdf = reader
                contents = reader.contents
            }
            // Allow layout and the initial location event to finish before tracking user movement.
            try await Task.sleep(nanoseconds: 350_000_000)
            try await initialCheckpoint()
            guard !closed else { return }
            ready = true
            await synchronize(flushFirst: false)
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
    private func initialCheckpoint() async throws {
        let updatedAt = positions.current?.updatedAt ?? Date()
        var position: ReadingPosition?
        if let navigator = activeEPUB, let epubPosition = epubPosition {
            if let saved = positions.current, let json = saved.locatorJSON,
               let locator = try Locator(jsonString: json), let pointer = saved.xpointer {
                func isOpening() -> Bool { activeEPUB === navigator && !closed && !Task.isCancelled }
                do {
                    try await epubPosition.restore(locator, pointer: pointer, in: navigator, isCurrent: isOpening)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await epubPosition.restore(locator, pointer: nil, in: navigator, isCurrent: isOpening)
                }
            }
            position = try await epubPosition.initialPosition(in: navigator, updatedAt: updatedAt)
            guard activeEPUB === navigator, !closed, !Task.isCancelled else { throw CancellationError() }
        } else if let pdf = pdf {
            position = try await pdf.open(at: positions.current?.pdfPage, updatedAt: updatedAt) {
                self.pdf === pdf && !self.closed && !Task.isCancelled
            }
            guard self.pdf === pdf, !closed, !Task.isCancelled else { throw CancellationError() }
        }
        if let position = position {
            try commit(position, from: .checkpoint, locator: activeEPUB?.currentLocation.map(adjusted))
        }
    }
    private func preferences() -> EPUBPreferences {
        let settings = store.settings.reader
        let dark = settings.theme.isDark ?? (container.traitCollection.userInterfaceStyle == .dark)
        let twoPages = displaysTwoPages && !isScrolling
        return EPUBPreferences(columnCount: twoPages ? .two : .one,
            fontFamily: FontFamily(rawValue: settings.font.familyName), fontSize: settings.fontSize / 100,
            lineHeight: settings.lineHeight, pageMargins: settings.pageMargins,
            publisherStyles: false, scroll: false, spread: twoPages ? .always : .never, theme: dark ? .dark : .light)
    }
    private func updatePageLayout(size: CGSize, idiom: UIUserInterfaceIdiom) {
        let twoPages = ReaderPageLayout.displaysTwoPages(size: size, idiom: idiom)
        pdf?.updateLayout(twoPages: twoPages)
        guard displaysTwoPages != twoPages else { return }
        displaysTwoPages = twoPages
        epub?.submitPreferences(preferences())
    }

    func updateScrollInsets(_ insets: UIEdgeInsets?) {
        guard scrollInsets != insets else { return }
        scrollInsets = insets
        continuous?.updateScrollInsets(insets ?? .zero)
        pdf?.updateScrollInsets(insets)
    }

    private func adjusted(_ locator: Locator) -> Locator { epubPosition?.adjusted(locator) ?? locator }
    func updatePreferences() {
        protectPosition()
        if let navigator = activeEPUB, isScrolling != (continuous != nil) {
            do { try installNavigator(publication: navigator.publication, locator: positions.checkpoint?.locator ?? positions.latestLocator) }
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
            navigator.onLocationChanged = { [weak self, weak navigator] location in
                guard let self = self, let navigator = navigator, self.continuous === navigator else { return }
                self.locationChanged(location)
            }
            navigator.onScrollBegan = { [weak self] in self?.positions.movementBegan() }
            navigator.onLinkActivated = { [weak self, weak navigator] link in
                guard let self, let navigator, self.continuous === navigator,
                      self.ready, self.isActive, !self.closed, self.positions.activity == .idle,
                      !self.container.isTurningPage else { return }
                // Reject any remote position already in flight before the navigation task starts.
                self.positions.movementBegan()
                let movementRevision = self.positions.movementRevision
                Task { [weak self, weak navigator] in
                    guard let self, let navigator, self.continuous === navigator,
                          self.positions.movementRevision == movementRevision else { return }
                    await self.navigate(to: .link(link))
                }
            }
            navigator.onError = { [weak self] error in self?.error = error.localizedDescription }
            navigator.onContentTap = { [weak self] in self?.toggleControls() }
            if let scrollInsets = scrollInsets { navigator.updateScrollInsets(scrollInsets) }
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
        let turnOrigin = pdfPageTurnOrigin.flatMap { origin in
            origin.revision == positions.revision && pdf === origin.reader ? origin.checkpoint : nil
        }
        pdfPageTurnOrigin = nil
        container.cancelPageTransition()
        guard ready, !closed else { return }
        savePendingLocation()
        positions.protect(turnOrigin ?? Checkpoint(position: positions.current, locator: positions.latestLocator,
            pdf: pdf?.checkpoint(at: positions.current?.pdfPage)))
        continuous?.cancelNavigation()
    }
    private func savePendingLocation() {
        guard ready, positions.activity == .idle, !closed else { return }
        do { try positions.savePendingLocation() }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    private func scheduleRestoration() -> Task<Void, Never>? {
        guard isActive, !closed else { return nil }
        return positions.restore { [weak self] checkpoint, revision in
            guard let self = self else { return }
            do {
                try await self.restorePosition(checkpoint, revision: revision)
            } catch is CancellationError {
                // Keep the checkpoint for the next foreground/layout completion.
            } catch {
                guard self.isCurrent(revision) else { return }
                self.recoveryError = error.localizedDescription
            }
        }
    }
    private func isCurrent(_ revision: Int) -> Bool {
        positions.isCurrent(revision) && isActive && !closed
    }

    private func restorePosition(_ checkpoint: Checkpoint, revision: Int) async throws {
        guard isCurrent(revision) else { throw CancellationError() }
        recoveryError = nil
        if let navigator = activeEPUB {
            if reloadNavigatorOnRecovery {
                try installNavigator(publication: navigator.publication, locator: checkpoint.locator)
            }
            guard let navigator = activeEPUB, let epubPosition = epubPosition, let location = checkpoint.locator else {
                throw AppFailure("Couldn’t read the last reading position.")
            }
            try await epubPosition.restore(location, pointer: checkpoint.position?.xpointer, in: navigator) {
                self.isCurrent(revision) && self.activeEPUB === navigator
            }
        } else if let saved = checkpoint.pdf, let pdf = pdf {
            _ = try await pdf.move(to: .checkpoint(saved)) {
                self.isCurrent(revision) && self.pdf === pdf
            }
        }
        guard isCurrent(revision) else { throw CancellationError() }
        if let navigator = activeEPUB, let epubPosition = epubPosition, let locator = navigator.currentLocation,
           var position = checkpoint.position, position.xpointer == nil {
            position.xpointer = try? await epubPosition.capture(locator, in: navigator)
            guard isCurrent(revision), activeEPUB === navigator else { throw CancellationError() }
            if position.xpointer != nil {
                try commit(position, from: .checkpoint)
            }
            updateBridgeWarning()
        }
        progression = checkpoint.position?.progression ?? progression
        reloadNavigatorOnRecovery = false
        positions.finishRestoration(at: activeEPUB?.currentLocation.map(adjusted))
    }
    func navigator(_ navigator: Navigator, presentError error: NavigatorError) { self.error = error.localizedDescription }
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let epub = epub, (navigator as AnyObject) === epub else { return }
        locationChanged(locator)
    }
    func pageTurnDidFinish(committed: Bool, error: Error?) async {
        if let error = error { self.error = error.localizedDescription }
        guard ready, isActive, positions.activity == .idle, !closed else { return }
        if let pdf = pdf {
            guard let origin = pdfPageTurnOrigin,
                  origin.revision == positions.revision, origin.reader === pdf else { return }
            if committed, let position = pdf.position() {
                pdfPageTurnOrigin = nil
                pdfChanged(position)
            } else {
                // Navigation may already have moved PDFKit before cancellation or
                // a failed confirmation. Restore the captured origin before unlocking.
                protectPosition()
                await scheduleRestoration()?.value
            }
            return
        }
        guard let navigator = epub, let epubPosition = epubPosition else { return }
        let revision = positions.revision
        if committed {
            do {
                let captured = try await epubPosition.settledPage(in: navigator)
                let locator = captured.locator
                let pointer = captured.pointer
                guard isCurrent(revision), epub === navigator else { return }
                try commit(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date()), from: .movement, locator: locator)
            } catch {
                guard isCurrent(revision), epub === navigator else { return }
                container.cancelPageTransition()
                self.error = error.localizedDescription
            }
        } else {
            positions.scheduleCapture { [weak self] locator, revision in
                await self?.captureEPUB(locator, revision: revision)
            }
        }
    }
    private func locationChanged(_ locator: Locator) {
        guard ready, isActive, positions.activity == .idle, !closed, !container.isTurningPage else { return }
        let locator = adjusted(locator)
        progression = locator.locations.totalProgression ?? progression
        positions.observe(locator) { [weak self] locator, revision in
            await self?.captureEPUB(locator, revision: revision)
        }
    }
    private func captureEPUB(_ locator: Locator, revision: Int) async {
        guard positions.isCurrent(revision), positions.activity == .idle, !closed, !container.isTurningPage,
              let navigator = activeEPUB, let epubPosition = epubPosition else { return }
        let pointer = try? await epubPosition.capture(locator, in: navigator)
        guard positions.isCurrent(revision), activeEPUB === navigator, !closed, !container.isTurningPage else { return }
        do {
            try commit(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date()), from: .movement, locator: locator)
            updateBridgeWarning()
        } catch { self.error = error.localizedDescription }
    }
    private func pdfChanged(_ position: ReadingPosition) {
        guard ready, isActive, positions.activity == .idle, !closed, position.pdfPage != positions.current?.pdfPage else { return }
        positions.movementBegan()
        do { try commit(position, from: .movement) }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    private func commit(_ position: ReadingPosition, from source: ReaderPositionSession.Source, locator: Locator? = nil) throws -> Bool {
        let changed = try positions.commit(position, from: source, locator: locator)
        progression = position.progression
        return changed
    }
    private func updateBridgeWarning() {
        bridgeWarning = positions.current?.xpointer == nil
            ? String(localized: "Couldn’t convert the current position. Local progress was saved and sync uploads are paused.")
            : nil
    }
    func flush() async {
        guard ready, positions.activity == .idle, !closed, !container.isTurningPage else { return }
        await positions.flush { locator, revision in
            await captureEPUB(locator, revision: revision)
        }
    }
    func close() async {
        pdfPageTurnOrigin = nil
        container.cancelPageTransition()
        positions.movementBegan()
        await flush()
        closed = true
        continuous?.close()
        positions.invalidate()
        await synchronize(flushFirst: false, applyRemote: false)
    }
    func resignActive() {
        guard !closed else { return }
        let interruptedPDFTurn = container.isTurningPage && pdfPageTurnOrigin.map {
            $0.revision == positions.revision && pdf === $0.reader
        } == true
        isActive = false
        if isNavigating || interruptedPDFTurn {
            // An interrupted navigation still needs to return to its original position.
            protectPosition()
        } else {
            pdfPageTurnOrigin = nil
            container.cancelPageTransition()
            // A live reader keeps its page when the app is merely interrupted.
            positions.invalidate()
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
        await scheduleRestoration()?.value
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
        guard ready, isActive, !closed, positions.activity == .idle else { return false }
        if isGesture {
            guard let epub = epub else { return false }
            return epub.publication.metadata.layout != .fixed && !epub.settings.scroll && epub.currentSelection == nil
        }
        return epub != nil || pdf != nil
    }

    func pageTurnWillBegin() {
        positions.invalidate()
        if let pdf = pdf {
            pdfPageTurnOrigin = (positions.revision, pdf,
                Checkpoint(position: positions.current, locator: nil, pdf: pdf.checkpoint(at: nil)))
        }
    }

    func movePage(towardLeft: Bool) async throws -> Bool {
        let revision = positions.revision
        if let epub = epub {
            let forward = towardLeft == (epub.presentation.readingProgression == .ltr)
            let options = NavigatorGoOptions(animated: false)
            let moved = forward ? await epub.goForward(options: options) : await epub.goBackward(options: options)
            guard isCurrent(revision), self.epub === epub else {
                throw CancellationError()
            }
            return moved
        }
        guard let pdf = pdf else { return false }
        return try await pdf.turn(forward: towardLeft) {
            self.isCurrent(revision) && self.pdf === pdf
        }
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
    @discardableResult
    func jump(toPage page: Int, onFailure: ((Error) -> Void)? = nil) async -> Bool {
        guard let count = pdfPageCount, (1...count).contains(page) else {
            let failure = AppFailure("Page number outside this book’s range.")
            if let onFailure { onFailure(failure) }
            else { error = failure.localizedDescription }
            return false
        }
        guard page != currentPDFPage else { return true }
        let succeeded = await navigate(to: .page(page - 1), onFailure: onFailure)
        return succeeded && currentPDFPage == page
    }
    func returnToPreviousPosition() async {
        guard let previousPosition = positions.previous else { return }
        await navigate(to: .checkpoint(previousPosition), returning: true)
    }

    private enum NavigationTarget {
        case progression(Double), link(ReadiumShared.Link), page(Int), checkpoint(Checkpoint)
    }
    @discardableResult
    private func move(to target: NavigationTarget, isCurrent: @MainActor () -> Bool) async throws -> ReadingPosition? {
        if let navigator = activeEPUB, let epubPosition = epubPosition {
            switch target {
            case .progression(let value):
                _ = try await epubPosition.go(toProgression: value, in: navigator, isCurrent: isCurrent)
            case .link(let link):
                try await epubPosition.go(to: link, in: navigator, isCurrent: isCurrent)
            case .checkpoint(let saved):
                try await epubPosition.restore(saved.locator, pointer: saved.position?.xpointer, in: navigator, isCurrent: isCurrent)
            case .page:
                throw AppFailure("Couldn’t jump to the selected position.")
            }
            return nil
        } else if let pdf = pdf {
            switch target {
            case .page(let index):
                return try await pdf.move(to: .page(index)) { isCurrent() && self.pdf === pdf }
            case .checkpoint(let saved):
                guard let checkpoint = saved.pdf else { throw AppFailure("Couldn’t return to the previous position.") }
                return try await pdf.move(to: .checkpoint(checkpoint)) { isCurrent() && self.pdf === pdf }
            default: throw AppFailure("Couldn’t jump to the selected position.")
            }
        }
        throw AppFailure("Couldn’t jump to the selected position.")
    }

    @discardableResult
    private func navigate(
        _ operation: @MainActor (@MainActor () -> Bool) async throws -> Void,
        onFailure: (Error) -> Void
    ) async -> Bool {
        guard ready, isActive, !closed, positions.activity == .idle, !container.isTurningPage else { return false }
        savePendingLocation()
        let navigator = activeEPUB
        let pdf = pdf
        var origin = Checkpoint(position: positions.current,
            locator: navigator?.currentLocation.map(adjusted) ?? positions.latestLocator,
            pdf: pdf?.checkpoint(at: nil))
        let revision = positions.beginNavigation(from: origin)
        defer { positions.finishNavigation(revision) }
        func ownsNavigation() -> Bool {
            revision == positions.revision && isActive && !closed && activeEPUB === navigator && self.pdf === pdf
        }
        func isCurrent() -> Bool { ownsNavigation() && !Task.isCancelled }
        do {
            if let navigator = navigator, let epubPosition = epubPosition, let locator = origin.locator {
                let pointer = try? await epubPosition.capture(locator, in: navigator)
                guard isCurrent() else { throw CancellationError() }
                let savedPointer = locator.jsonString == origin.position?.locatorJSON ? origin.position?.xpointer : nil
                origin = Checkpoint(position: ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, xpointer: pointer ?? savedPointer,
                    updatedAt: origin.position?.updatedAt ?? Date()), locator: locator, pdf: nil)
                positions.refineOrigin(origin)
            }
            try await operation(isCurrent)
            return true
        } catch {
            guard ownsNavigation() else { return false }
            if isCurrent(), !(error is CancellationError) {
                do {
                    try await move(to: .checkpoint(origin), isCurrent: isCurrent)
                    guard isCurrent() else { throw CancellationError() }
                    progression = origin.position?.progression ?? progression
                    onFailure(error)
                    return false
                } catch {
                    guard ownsNavigation() else { return false }
                }
            }
            positions.protect(origin)
            continuous?.cancelNavigation()
            scheduleRestoration()
            return false
        }
    }

    @discardableResult
    private func navigate(to target: NavigationTarget, returning: Bool = false, onFailure: ((Error) -> Void)? = nil) async -> Bool {
        let succeeded = await navigate { isCurrent in
            let navigator = activeEPUB
            let pdfPosition = try await move(to: target, isCurrent: isCurrent)
            guard isCurrent() else { throw CancellationError() }
            let changed: Bool
            if let navigator = navigator, let epubPosition = epubPosition, let locator = navigator.currentLocation.map(adjusted) {
                let pointer: String?
                do { pointer = try await epubPosition.capture(locator, in: navigator) }
                catch is CancellationError where navigator is ContinuousEPUBController { throw CancellationError() }
                catch { pointer = nil }
                guard isCurrent() else { throw CancellationError() }
                changed = try commit(ReadingPosition(progression: locator.locations.totalProgression ?? progression,
                    locatorJSON: locator.jsonString, xpointer: pointer, updatedAt: Date()), from: .movement, locator: locator)
                updateBridgeWarning()
            } else if let pdfPosition = pdfPosition {
                changed = try commit(pdfPosition, from: .movement)
            } else {
                throw AppFailure("Couldn’t jump to the selected position.")
            }
            if changed || returning {
                positions.rememberOrigin(returning: returning)
                canReturnToPreviousPosition = positions.previous != nil
            }
        } onFailure: { error in
            if let onFailure { onFailure(error) }
            else { self.error = error.localizedDescription }
        }
        if !closed, positions.activity == .idle { await refreshContentsPosition() }
        return succeeded
    }
    func synchronize(preferLocal: Bool = false, flushFirst: Bool = true, userInitiated: Bool = false, applyRemote: Bool = true) async {
        guard ready, !busySync, !isNavigating, (!isRestoring || !applyRemote), !container.isTurningPage, prompt == nil else { return }
        busySync = true; defer { busySync = false }
        let revision = positions.movementRevision
        syncNotice = nil
        syncError = nil
        do {
            // Save the latest page before the coordinator takes a snapshot.
            if flushFirst { await flush() }
            if let error = positions.persistenceError { throw error }
            let outcome = try await sync.synchronize(bookID, preferLocal: preferLocal)
            switch outcome {
            case .idle: break
            case .conflict(let remote), .remote(let remote):
                // A network response must not override a turn made while awaiting it,
                // even if the 400 ms position capture has not reached the store yet.
                guard applyRemote, canApplyRemote(revision: revision) else {
                    syncNotice = String(localized: "Your current reading position was kept. Sync again later.")
                    return
                }
                if case .conflict = outcome {
                    prompt = SyncPrompt(kind: .conflict, remote: remote, revision: revision)
                } else if !userInitiated && remote.fingerprint == offeredApproximateFingerprint {
                    syncNotice = String(localized: "Couldn’t resolve the exact remote position. Local progress was kept.")
                } else {
                    await receive(remote, revision: revision)
                }
            }
        } catch { syncError = String(localized: "Sync failed: \(error.localizedDescription)") }
    }
    private func canApplyRemote(revision: Int) -> Bool {
        !closed && isActive && !Task.isCancelled && positions.activity == .idle &&
            !container.isTurningPage && continuous?.isScrolling != true && pdf?.isScrolling != true &&
            positions.movementRevision == revision
    }

    func receive(_ remote: RemoteProgress, approximate: Bool = false, revision: Int? = nil) async {
        guard ready, canApplyRemote(revision: revision ?? positions.movementRevision) else { return }
        syncNotice = nil
        syncError = nil
        await navigate { isCurrent in
            if let navigator = activeEPUB, let epubPosition = epubPosition {
                let locator: Locator
                if approximate {
                    guard let percentage = remote.percentage else { throw AppFailure("Couldn’t locate the position by percentage.") }
                    locator = try await epubPosition.go(toProgression: percentage, in: navigator, isCurrent: isCurrent)
                } else {
                    guard let pointer = remote.progress else { throw AppFailure("No remote reading position is available.") }
                    locator = try await epubPosition.go(toPointer: pointer, in: navigator, isCurrent: isCurrent)
                }
                guard isCurrent() else { throw CancellationError() }
                let visible = navigator.currentLocation.map(adjusted) ?? locator
                try commit(ReadingPosition(progression: remote.percentage ?? visible.locations.totalProgression ?? 0,
                    locatorJSON: visible.jsonString,
                    xpointer: approximate ? nil : remote.progress, updatedAt: Date()), from: .remote(remote),
                    locator: visible)
            } else {
                guard let raw = remote.progress, let page = Int(raw), let pdf = pdf, (1...pdf.pageCount).contains(page) else {
                    throw AppFailure("The remote PDF page number is outside this book’s range.")
                }
                let position = try await pdf.move(to: .page(page - 1)) { isCurrent() && self.pdf === pdf }
                guard isCurrent() else { throw CancellationError() }
                try commit(position, from: .remote(remote))
            }
            bridgeWarning = nil
        } onFailure: { error in
            syncError = String(localized: "Sync failed: \(error.localizedDescription)")
            if activeEPUB != nil && !approximate {
                offeredApproximateFingerprint = remote.fingerprint
                prompt = SyncPrompt(kind: .approximate, remote: remote, revision: positions.movementRevision)
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
}

private enum ReaderFonts {
    static let latin = FontFamily(rawValue: ReaderFont.serif.familyName)
    static let cjk: FontFamily = "LXGW WenKai"

    static func declarations() throws -> [AnyHTMLFontFamilyDeclaration] {
        func face(_ name: String, style: CSSFontStyle = .normal, weight: CSSStandardFontWeight = .normal) throws -> CSSFontFace {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                  let file = FileURL(url: url) else {
                throw AppFailure("Missing reading font: \(name)")
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
