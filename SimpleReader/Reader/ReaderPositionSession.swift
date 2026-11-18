import Foundation
import ReadiumShared

/// The lifetime of the position, pending capture, and interaction lock is one open book.
@MainActor final class ReaderPositionSession {
    struct Checkpoint {
        let position: ReadingPosition?
        let locator: Locator?
        let pdf: PDFReader.Checkpoint?
    }

    enum Source {
        case checkpoint, movement, remote(RemoteProgress)
    }

    enum Activity { case idle, navigating, turningPage, restoring }

    struct Navigation: Equatable {
        enum Kind { case jump, pageTurn }
        let kind: Kind
        fileprivate let revision: Int
    }

    enum History { case unchanged, rememberOrigin, returning }

    private enum State {
        case idle
        case navigating(Navigation, origin: Checkpoint)
        case restoring(Checkpoint)

        var activity: Activity {
            switch self {
            case .idle: return .idle
            case .navigating(let navigation, _): return navigation.kind == .pageTurn ? .turningPage : .navigating
            case .restoring: return .restoring
            }
        }
    }

    private let bookID: UUID
    private let store: LibraryStore
    private let sync: SyncCoordinator
    private(set) var current: ReadingPosition?
    private(set) var latestLocator: Locator?
    private var pendingLocator: Locator?
    private var capture: Task<Void, Never>?
    private var restoration: Task<Void, Never>?
    private(set) var previous: Checkpoint?
    private var state = State.idle {
        didSet { if activity != oldValue.activity { onActivityChanged?(activity) } }
    }
    var activity: Activity { state.activity }
    var checkpoint: Checkpoint? {
        if case .restoring(let checkpoint) = state { return checkpoint }
        return nil
    }
    var pageTurn: Navigation? {
        guard case .navigating(let navigation, _) = state, navigation.kind == .pageTurn else { return nil }
        return navigation
    }
    var onActivityChanged: ((Activity) -> Void)?
    private(set) var revision = 0
    private(set) var movementRevision = 0
    private(set) var persistenceError: Error?

    init(bookID: UUID, store: LibraryStore, sync: SyncCoordinator) {
        self.bookID = bookID
        self.store = store
        self.sync = sync
        current = store.book(bookID)?.position
    }

    deinit {
        capture?.cancel()
        restoration?.cancel()
    }

    func isCurrent(_ revision: Int) -> Bool { self.revision == revision && !Task.isCancelled }

    func invalidate() {
        revision += 1
        movementBegan()
        capture?.cancel()
        restoration?.cancel()
    }

    func movementBegan() { movementRevision += 1 }

    func beginNavigation(_ kind: Navigation.Kind, from checkpoint: Checkpoint) -> Navigation {
        invalidate()
        let navigation = Navigation(kind: kind, revision: revision)
        state = .navigating(navigation, origin: checkpoint)
        return navigation
    }

    func origin(of navigation: Navigation) -> Checkpoint? {
        guard case .navigating(let current, let origin) = state,
              current == navigation, navigation.revision == revision else { return nil }
        return origin
    }

    func refineOrigin(_ checkpoint: Checkpoint, for navigation: Navigation) {
        guard origin(of: navigation) != nil else { return }
        state = .navigating(navigation, origin: checkpoint)
    }

    func finishNavigation(_ navigation: Navigation) {
        guard origin(of: navigation) != nil else { return }
        state = .idle
    }

    func commitNavigation(_ navigation: Navigation, position: ReadingPosition, from source: Source,
                          locator: Locator? = nil, history: History = .unchanged) throws {
        guard !Task.isCancelled, let origin = origin(of: navigation) else { throw CancellationError() }
        let changed = try commit(position, from: source, locator: locator)
        switch history {
        case .rememberOrigin where changed: previous = origin
        case .returning: previous = nil
        default: break
        }
    }

    func protect(_ fallback: @autoclosure () -> Checkpoint) {
        let saved: Checkpoint
        switch state {
        case .idle: saved = fallback()
        case .navigating(_, let origin), .restoring(let origin): saved = origin
        }
        invalidate()
        state = .restoring(saved)
    }

    func recover(_ navigation: Navigation) {
        guard let origin = origin(of: navigation) else { return }
        protect(origin)
    }

    @discardableResult
    func restore(using restore: @escaping (Checkpoint, Int) async -> Void) -> Task<Void, Never>? {
        guard let checkpoint = checkpoint else { return nil }
        invalidate()
        let revision = revision
        let task = Task {
            // Coalesce resizing and the resulting column preference change.
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            await restore(checkpoint, revision)
        }
        restoration = task
        return task
    }

    func finishRestoration(at locator: Locator?) {
        latestLocator = locator
        pendingLocator = nil
        state = .idle
    }

    func observe(_ locator: Locator, capture: @escaping (Locator, Int) async -> Void) {
        guard locator.jsonString != latestLocator?.jsonString else { return }
        latestLocator = locator
        pendingLocator = locator.jsonString == current?.locatorJSON ? nil : locator
        invalidate()
        scheduleCapture(capture)
    }

    func scheduleCapture(_ capture: @escaping (Locator, Int) async -> Void) {
        guard let locator = pendingLocator else { return }
        self.capture?.cancel()
        let revision = revision
        self.capture = Task {
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            await capture(locator, revision)
        }
    }

    func flush(using capture: (Locator, Int) async -> Void) async {
        guard let locator = pendingLocator else { return }
        self.capture?.cancel()
        revision += 1
        await capture(locator, revision)
    }

    func savePendingLocation() throws {
        guard let locator = pendingLocator, locator.jsonString != current?.locatorJSON else { return }
        // Keep the locator usable if the process stops before text capture finishes.
        try commit(ReadingPosition(progression: locator.locations.totalProgression ?? current?.progression ?? 0,
            locatorJSON: locator.jsonString, updatedAt: Date()), from: .movement)
    }

    @discardableResult
    func commit(_ position: ReadingPosition, from source: Source, locator: Locator? = nil) throws -> Bool {
        var position = position
        var changed = false
        do {
            guard var book = store.book(bookID) else { throw AppFailure("The book has been deleted.") }
            switch source {
            case .remote(let remote):
                try sync.acceptRemote(remote, id: bookID, position: position)
            case .checkpoint, .movement:
                if case .movement = source {
                    let old = book.position
                    if let oldPointer = old?.xpointer, let pointer = position.xpointer {
                        changed = oldPointer != pointer
                    } else {
                        changed = old?.pdfPage != position.pdfPage || old?.locatorJSON != position.locatorJSON
                    }
                    if changed {
                        book.pendingSync = true
                    } else if let old = old {
                        position.updatedAt = old.updatedAt
                        position.xpointer = position.xpointer ?? old.xpointer
                    }
                }
                if book.position != position {
                    book.position = position
                    try store.save(book)
                }
            }
            current = position
            if let locator = locator {
                latestLocator = locator
                pendingLocator = nil
            }
            persistenceError = nil
            return changed
        } catch {
            persistenceError = error
            throw error
        }
    }
}
