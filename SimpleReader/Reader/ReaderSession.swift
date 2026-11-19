import SwiftUI
import Combine
import Observation
import ReadiumShared

@Observable @MainActor final class ReaderSession: ReaderPageTurnDelegate {
    let bookID: UUID
    var container: ReaderContainerController { renderer.container }
    private(set) var ready = false
    private(set) var controlsVisible = true
    var supportsScrolling: Bool { epub?.supportsScrolling ?? false }
    private(set) var isRestoring = false
    private(set) var isNavigating = false
    private(set) var canReturnToPreviousPosition = false
    private(set) var recoveryError: String?
    var error: String?
    var bridgeWarning: String?
    var syncError: String? { progressSync.error }
    var syncMessage: String? { progressSync.message }
    var progression: Double = 0
    var contents: [ContentsItem] { renderer.contents }
    private(set) var currentContentsID: UUID?
    var prompt: SyncPrompt? { progressSync.prompt }
    private let store: LibraryStore
    private let renderer: ReaderRenderer
    let sync: SyncCoordinator
    @ObservationIgnored private var libraryUpdates: Set<AnyCancellable> = []
    private(set) var title: String
    private(set) var bookFormat: BookFormat?
    private(set) var readerSettings: ReaderSettings
    private let positions: ReaderPositionSession
    @ObservationIgnored private lazy var progressSync = ReaderSyncSession(
        bookID: bookID, coordinator: sync, positions: positions,
        availability: { [weak self] in self?.syncAvailability ?? .unavailable },
        flush: { [weak self] in await self?.flush() },
        move: { [weak self] remote, approximate, onFailure in
            await self?.moveToRemotePosition(remote, approximate: approximate, onFailure: onFailure)
        })
    private var epub: EPUBReader? { renderer.epub }
    private var pdf: PDFReader? { renderer.pdf }
    private var loading = false
    private var closed = false
    private var isActive = true
    // Allow recovery during initial layout until UIKit reports a disappearance.
    private var isReaderVisible = true
    @ObservationIgnored private var visibilityRevision = 0
    private var reloadNavigatorOnRecovery = false
    private typealias Checkpoint = ReaderPositionSession.Checkpoint

    init(bookID: UUID, store: LibraryStore, readium: ReadiumService, sync: SyncCoordinator) {
        self.bookID = bookID; self.store = store; self.sync = sync
        renderer = ReaderRenderer(readium: readium) { store.settings.reader }
        title = store.book(bookID)?.title ?? String(localized: "Reading")
        bookFormat = store.book(bookID)?.format
        readerSettings = store.settings.reader
        positions = ReaderPositionSession(bookID: bookID, store: store, sync: sync)
        progression = positions.current?.progression ?? 0
        positions.onActivityChanged = { [weak self] activity in
            guard let self = self else { return }
            self.isRestoring = activity == .restoring
            self.isNavigating = activity == .navigating
            self.container.allowsContentInteraction = !self.closed && activity != .navigating && activity != .restoring
            if activity == .idle { self.progressSync.scheduleAutomaticCheck() }
        }
        renderer.onEvent = { [weak self] in self?.rendererDidEmit($0) }
        container.onLayoutWillChange = { [weak self] in self?.protectPosition() }
        container.onLayoutDidChange = { [weak self] in self?.scheduleRestoration() }
        container.onPageTurnEnded = { [weak self] in self?.progressSync.scheduleAutomaticCheck() }
        container.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            self.isReaderVisible = visible
            if visible {
                Task { [weak self] in await self?.resumeWhenVisible() }
            } else {
                self.visibilityRevision += 1
                if self.positions.activity == .restoring { self.positions.invalidate() }
            }
        }
        container.onAppearanceChange = { [weak self] in
            guard let self = self, self.store.settings.reader.theme == .system else { return }
            self.updatePreferences()
        }
        container.pageTurnDelegate = self

        // Project only the current book's metadata and reading preferences into the screen.
        store.$books.sink { [weak self] books in
            guard let self else { return }
            let book = books.first { $0.id == bookID }
            let title = book?.title ?? String(localized: "Reading")
            if self.title != title { self.title = title }
            if self.bookFormat != book?.format { self.bookFormat = book?.format }
        }.store(in: &libraryUpdates)
        store.$settings.map(\.reader).removeDuplicates().sink { [weak self] settings in
            self?.readerSettings = settings
        }.store(in: &libraryUpdates)
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
    var isScrolling: Bool { supportsScrolling && readerSettings.layout == .scroll }
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
        guard let epub else { return }
        let revision = positions.revision
        let contentsID = await epub.contentsID()
        guard positions.isCurrent(revision), self.epub === epub, !closed else { return }
        currentContentsID = contentsID
    }
    func load() async {
        guard !loading, !closed else { return }; loading = true
        do {
            guard var book = store.book(bookID) else { throw AppFailure("The book has been deleted.") }
            book.lastOpenedAt = Date(); try store.save(book)
            try await renderer.open(book, at: store.fileURL(book.filePath))
            // Allow layout and the initial location event to finish before tracking user movement.
            try await Task.sleep(nanoseconds: 350_000_000)
            try await initialCheckpoint()
            guard !closed else { return }
            ready = true
            await progressSync.checkOnOpen()
        } catch is CancellationError {
        } catch {
            guard !closed, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    private func initialCheckpoint() async throws {
        let updatedAt = positions.current?.updatedAt ?? Date()
        var position: ReadingPosition?
        if let epub {
            let snapshot = try await epub.initialSnapshot(restoring: positions.current) {
                self.epub === epub && !self.closed && !Task.isCancelled
            }
            guard self.epub === epub, !closed, !Task.isCancelled else { throw CancellationError() }
            position = snapshot?.position
        } else if let pdf = pdf {
            position = try await pdf.open(at: positions.current?.pdfPage, updatedAt: updatedAt) {
                self.pdf === pdf && !self.closed && !Task.isCancelled
            }
            guard self.pdf === pdf, !closed, !Task.isCancelled else { throw CancellationError() }
        }
        if let position = position {
            try commit(position, from: .checkpoint, locator: epub?.currentLocation)
        }
    }
    func updateScrollInsets(_ insets: UIEdgeInsets?) {
        renderer.updateScrollInsets(insets)
    }

    func saveReaderSettings(_ change: (inout ReaderSettings) -> Void) throws {
        try store.updateReaderSettings(change)
        updatePreferences()
    }

    func updatePreferences() {
        protectPosition()
        do {
            try renderer.updatePreferences(at: positions.checkpoint?.locator ?? positions.latestLocator)
        } catch { recoveryError = error.localizedDescription }
        scheduleRestoration()
    }

    private func rendererDidEmit(_ event: ReaderRenderer.Event) {
        switch event {
        case .pdfPageChanged(let position):
            pdfChanged(position)
        case .pdfMovementBegan:
            positions.movementBegan()
        case .pdfTapped(let point, let bounds):
            contentTapped(at: point, in: bounds)
        case .missingSpine:
            bridgeWarning = String(localized: "Couldn’t read the original chapter order. EPUB sync is paused.")
        case .epub(let event, let epub):
            switch event {
            case .locationChanged(let locator):
                self.locationChanged(locator)
            case .movementBegan:
                self.positions.movementBegan()
            case .linkActivated(let link):
                guard self.ready, self.isActive, !self.closed, self.positions.activity == .idle,
                      !self.container.isTurningPage else { return }
                // Reject any remote position already in flight before the navigation task starts.
                self.positions.movementBegan()
                let movementRevision = self.positions.movementRevision
                Task { [weak self, weak epub] in
                    guard let self, let epub, self.epub === epub,
                          self.positions.movementRevision == movementRevision else { return }
                    await self.navigate(to: .link(link))
                }
            case .tapped(let point, let bounds):
                self.contentTapped(at: point, in: bounds)
            case .toggleControls:
                self.toggleControls()
            case .error(let error):
                self.error = error.localizedDescription
            }
        }
    }
    private func protectPosition() {
        guard ready, !closed else {
            container.cancelPageTransition()
            return
        }
        savePendingLocation()
        positions.protect(Checkpoint(position: positions.current, locator: positions.latestLocator,
            pdf: pdf?.checkpoint(at: positions.current?.pdfPage)))
        container.cancelPageTransition()
        epub?.cancelNavigation()
    }

    private func recover(_ navigation: ReaderPositionSession.Navigation) {
        positions.recover(navigation)
        epub?.cancelNavigation()
        scheduleRestoration()
    }
    private func savePendingLocation() {
        guard ready, positions.activity == .idle, !closed else { return }
        do { try positions.savePendingLocation() }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    private func scheduleRestoration() -> Task<Void, Never>? {
        guard isActive, isReaderVisible, !closed else { return nil }
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
        if epub != nil {
            if reloadNavigatorOnRecovery {
                try renderer.rebuildEPUB(at: checkpoint.locator)
            }
            guard let epub, let location = checkpoint.locator else {
                throw AppFailure("Couldn’t read the last reading position.")
            }
            try await epub.move(to: .checkpoint(location, pointer: checkpoint.position?.xpointer)) {
                self.isCurrent(revision) && self.epub === epub
            }
        } else if let saved = checkpoint.pdf, let pdf = pdf {
            _ = try await pdf.move(to: .checkpoint(saved)) {
                self.isCurrent(revision) && self.pdf === pdf
            }
        }
        guard isCurrent(revision) else { throw CancellationError() }
        if let epub, let locator = epub.currentLocation,
           var position = checkpoint.position, position.xpointer == nil {
            let captured = try? await epub.capture(.movement(locator), fallbackProgression: progression)
            position.xpointer = captured?.position.xpointer
            guard isCurrent(revision), self.epub === epub else { throw CancellationError() }
            if position.xpointer != nil {
                try commit(position, from: .checkpoint)
            }
            updateBridgeWarning()
        }
        progression = checkpoint.position?.progression ?? progression
        reloadNavigatorOnRecovery = false
        positions.finishRestoration(at: epub?.currentLocation)
    }
    func pageTurnDidFinish(_ outcome: PageTurnOutcome) async {
        guard let navigation = positions.pageTurn, ownsNavigation(navigation) else { return }
        defer { positions.finishNavigation(navigation) }
        switch outcome {
        case .unchanged:
            discardPageTurn(navigation)
            return
        case .restoreOrigin(let error):
            if let error { self.error = error.localizedDescription }
            recover(navigation)
            return
        case .settled:
            break
        }

        do {
            let destination: NavigationDestination
            if let pdf, let position = pdf.position() {
                destination = NavigationDestination(position: position)
            } else if let epub, let captured = try await epub.capture(.settledPage, fallbackProgression: progression) {
                guard ownsNavigation(navigation), self.epub === epub else { return }
                destination = NavigationDestination(position: captured.position, locator: captured.locator)
            } else {
                recover(navigation)
                return
            }
            try positions.commitNavigation(navigation, position: destination.position, from: .movement, locator: destination.locator)
            progression = destination.position.progression
        } catch {
            guard ownsNavigation(navigation) else { return }
            if error is CancellationError {
                recover(navigation)
            } else if epub != nil {
                // Keep Readium usable when the displayed position cannot be recorded.
                positions.finishNavigation(navigation)
                container.cancelPageTransition()
                self.error = error.localizedDescription
            } else {
                self.error = error.localizedDescription
                recover(navigation)
            }
        }
    }

    func pageTurnWasCancelled(needsRestoration: Bool) {
        guard let navigation = positions.pageTurn else { return }
        if needsRestoration { recover(navigation) }
        else { discardPageTurn(navigation) }
    }

    private func discardPageTurn(_ navigation: ReaderPositionSession.Navigation) {
        positions.finishNavigation(navigation)
        positions.scheduleCapture { [weak self] locator, revision in
            await self?.captureEPUB(locator, revision: revision)
        }
    }

    private func ownsNavigation(_ navigation: ReaderPositionSession.Navigation) -> Bool {
        isActive && !closed && positions.origin(of: navigation) != nil
    }

    private func locationChanged(_ locator: Locator) {
        guard ready, isActive, positions.activity == .idle, !closed, !container.isTurningPage else { return }
        progression = locator.locations.totalProgression ?? progression
        positions.observe(locator) { [weak self] locator, revision in
            await self?.captureEPUB(locator, revision: revision)
        }
    }
    private func captureEPUB(_ locator: Locator, revision: Int) async {
        guard positions.isCurrent(revision), positions.activity == .idle, !closed, !container.isTurningPage,
              let epub else { return }
        let captured = try? await epub.capture(.movement(locator), fallbackProgression: progression)
        guard positions.isCurrent(revision), self.epub === epub, !closed, !container.isTurningPage,
              let captured else { return }
        do {
            try commit(captured.position, from: .movement, locator: captured.locator)
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
        progressSync.discardAutomaticCheck()
        let turn = positions.pageTurn
        if let turn { positions.finishNavigation(turn) }
        container.cancelPageTransition()
        positions.movementBegan()
        // The viewport can still show an unconfirmed turn. Its origin was saved at the start.
        if turn == nil { await flush() }
        closed = true
        progressSync.discardAutomaticCheck()
        renderer.close()
        positions.invalidate()
        await progressSync.synchronize(.leaving)
    }
    func resignActive() {
        guard !closed else { return }
        isActive = false
        if positions.activity == .navigating || positions.activity == .turningPage {
            protectPosition()
        } else {
            container.cancelPageTransition()
            // A live reader keeps its page when the app is merely interrupted.
            positions.invalidate()
            savePendingLocation()
        }
    }
    func background() async {
        guard !closed else { return }
        resignActive()
        progressSync.requestForegroundCheck()
        await flush()
        await progressSync.synchronize(.leaving)
    }
    func foreground() async {
        guard !closed else { return }
        isActive = true
        await resumeWhenVisible()
    }
    private func resumeWhenVisible() async {
        await scheduleRestoration()?.value
        await progressSync.resumeAutomaticCheck()
    }
    func retryRecovery() async {
        guard !closed else { return }
        protectPosition()
        reloadNavigatorOnRecovery = true
        await foreground()
    }
    func turn(forward: Bool) async {
        let towardLeft = epub?.towardLeft(forward: forward) ?? forward
        await container.turnPage(towardLeft: towardLeft)
    }

    func canBeginPageTurn(isGesture: Bool) -> Bool {
        guard ready, isActive, !closed, positions.activity == .idle else { return false }
        if let epub { return epub.canBeginPageTurn(isGesture: isGesture) }
        return !isGesture && pdf != nil
    }

    func pageTurnWillBegin() {
        guard canBeginPageTurn(isGesture: false) else { return }
        _ = beginNavigation(.pageTurn)
    }

    func movePage(towardLeft: Bool) async throws -> Bool {
        guard let navigation = positions.pageTurn, ownsNavigation(navigation) else { return false }
        if let epub {
            return try await epub.movePage(towardLeft: towardLeft) {
                self.ownsNavigation(navigation) && self.epub === epub
            }
        }
        guard let pdf else { return false }
        return try await pdf.turn(forward: towardLeft) {
            self.ownsNavigation(navigation) && self.pdf === pdf
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
        if let epub {
            switch target {
            case .progression(let value):
                try await epub.move(to: .progression(value), isCurrent: isCurrent)
            case .link(let link):
                try await epub.move(to: .link(link), isCurrent: isCurrent)
            case .checkpoint(let saved):
                try await epub.move(to: .checkpoint(saved.locator, pointer: saved.position?.xpointer), isCurrent: isCurrent)
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

    private struct NavigationDestination {
        let position: ReadingPosition
        var locator: Locator?
    }

    private func beginNavigation(_ kind: ReaderPositionSession.Navigation.Kind) -> ReaderPositionSession.Navigation {
        savePendingLocation()
        // A settled turn records its locator before Readium publishes the location change.
        let locator = kind == .pageTurn
            ? positions.latestLocator ?? epub?.currentLocation
            : epub?.currentLocation ?? positions.latestLocator
        let origin = Checkpoint(position: positions.current, locator: locator, pdf: pdf?.checkpoint(at: nil))
        return positions.beginNavigation(kind, from: origin)
    }

    @discardableResult
    private func navigate(
        from source: ReaderPositionSession.Source,
        history: ReaderPositionSession.History = .unchanged,
        _ operation: @MainActor (@MainActor () -> Bool) async throws -> NavigationDestination,
        onFailure: (Error) -> Void
    ) async -> Bool {
        guard ready, isActive, !closed, positions.activity == .idle, !container.isTurningPage else { return false }
        let epub = epub
        let pdf = pdf
        let visibilityRevision = visibilityRevision
        let navigation = beginNavigation(.jump)
        defer { positions.finishNavigation(navigation) }
        func ownsRenderer() -> Bool { ownsNavigation(navigation) && self.epub === epub && self.pdf === pdf }
        func isCurrent() -> Bool {
            guard ownsRenderer(), !Task.isCancelled else { return false }
            if case .remote = source { return isReaderVisible && self.visibilityRevision == visibilityRevision }
            return true
        }
        do {
            if let epub, let origin = positions.origin(of: navigation), let locator = origin.locator {
                let captured = try await epub.capture(.origin(locator, saved: origin.position), fallbackProgression: progression)
                guard isCurrent() else { throw CancellationError() }
                if let captured {
                    positions.refineOrigin(Checkpoint(position: captured.position, locator: captured.locator, pdf: nil), for: navigation)
                }
            }
            let destination = try await operation(isCurrent)
            guard isCurrent() else { throw CancellationError() }
            try positions.commitNavigation(navigation, position: destination.position, from: source,
                locator: destination.locator, history: history)
            progression = destination.position.progression
            canReturnToPreviousPosition = positions.previous != nil
            switch source {
            case .movement where epub != nil: updateBridgeWarning()
            case .remote: bridgeWarning = nil
            default: break
            }
            return true
        } catch {
            guard ownsRenderer(), let origin = positions.origin(of: navigation) else { return false }
            if isCurrent(), !(error is CancellationError) {
                do {
                    try await move(to: .checkpoint(origin), isCurrent: isCurrent)
                    guard isCurrent() else { throw CancellationError() }
                    progression = origin.position?.progression ?? progression
                    onFailure(error)
                    return false
                } catch {
                    guard ownsRenderer() else { return false }
                }
            }
            recover(navigation)
            return false
        }
    }

    @discardableResult
    private func navigate(to target: NavigationTarget, returning: Bool = false, onFailure: ((Error) -> Void)? = nil) async -> Bool {
        let succeeded = await navigate(from: .movement, history: returning ? .returning : .rememberOrigin) { isCurrent in
            let epub = epub
            let pdfPosition = try await move(to: target, isCurrent: isCurrent)
            guard isCurrent() else { throw CancellationError() }
            if let epub, let captured = try await epub.capture(.navigation, fallbackProgression: progression) {
                return NavigationDestination(position: captured.position, locator: captured.locator)
            }
            if let pdfPosition { return NavigationDestination(position: pdfPosition) }
            throw AppFailure("Couldn’t jump to the selected position.")
        } onFailure: { error in
            if let onFailure { onFailure(error) }
            else { self.error = error.localizedDescription }
        }
        if !closed, positions.activity == .idle { await refreshContentsPosition() }
        return succeeded
    }

    func synchronize() async {
        await progressSync.synchronize(.manual)
    }

    private var syncAvailability: ReaderSyncSession.Availability {
        guard ready, !container.isTurningPage else { return .unavailable }
        switch positions.activity {
        case .navigating, .turningPage: return .unavailable
        case .restoring: return .restoring
        case .idle:
            guard isActive, isReaderVisible, !closed else { return .inactive }
            return .reading(isScrolling: epub?.isUserScrolling == true || pdf?.isScrolling == true)
        }
    }

    func respond(to prompt: SyncPrompt, with response: SyncPrompt.Response) async {
        await progressSync.respond(to: prompt, with: response)
    }

    private func moveToRemotePosition(_ remote: RemoteProgress, approximate: Bool,
                                      onFailure: @MainActor (ReaderSyncSession.RemoteMoveFailure) -> Void) async {
        await navigate(from: .remote(remote)) { isCurrent in
            if let epub {
                let captured = try await epub.remoteSnapshot(remote, approximate: approximate, isCurrent: isCurrent)
                return NavigationDestination(position: captured.position, locator: captured.locator)
            } else {
                guard let raw = remote.progress, let page = Int(raw), let pdf = pdf, (1...pdf.pageCount).contains(page) else {
                    throw AppFailure("The remote PDF page number is outside this book’s range.")
                }
                let position = try await pdf.move(to: .page(page - 1)) { isCurrent() && self.pdf === pdf }
                return NavigationDestination(position: position)
            }
        } onFailure: { error in
            onFailure(.init(error: error, canApproximate: epub != nil))
        }
    }
}
