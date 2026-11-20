import Foundation
import Observation

/// Protects the current position before changes and restores it once the viewport can move.
@Observable @MainActor final class ReaderRecovery {
    enum Event {
        case checkpointSaveFailed(Error)
        case restored(ReadingPosition?, checkedPointer: Bool)
    }

    private typealias Checkpoint = ReaderPositionSession.Checkpoint
    private let renderer: ReaderRenderer
    private let positions: ReaderPositionSession
    private let canProtect: @MainActor () -> Bool
    private let canRestore: @MainActor () -> Bool
    private let onEvent: @MainActor (Event) -> Void
    @ObservationIgnored private var rebuildOnRestore = false
    private(set) var error: String?

    init(renderer: ReaderRenderer, positions: ReaderPositionSession, canProtect: @escaping @MainActor () -> Bool,
         canRestore: @escaping @MainActor () -> Bool, onEvent: @escaping @MainActor (Event) -> Void) {
        self.renderer = renderer
        self.positions = positions
        self.canProtect = canProtect
        self.canRestore = canRestore
        self.onEvent = onEvent
    }

    func protect() {
        guard canProtect() else {
            renderer.container.cancelPageTransition()
            return
        }
        savePendingLocation()
        positions.protect(Checkpoint(position: positions.current, locator: positions.latestLocator,
            pdf: renderer.pdf?.checkpoint(at: positions.current?.pdfPage)))
        renderer.container.cancelPageTransition()
        renderer.epub?.cancelNavigation()
    }

    func applyPreferences() {
        protect()
        do {
            try renderer.updatePreferences(at: positions.checkpoint?.locator ?? positions.latestLocator)
        } catch { self.error = error.localizedDescription }
        schedule()
    }

    func suspend() {
        if positions.activity == .navigating || positions.activity == .turningPage {
            protect()
        } else {
            renderer.container.cancelPageTransition()
            // A live reader keeps its page when the app is merely interrupted.
            positions.invalidate()
            savePendingLocation()
        }
    }

    func readerDidDisappear() {
        if positions.activity == .restoring { positions.invalidate() }
    }

    func prepareRetry() {
        protect()
        rebuildOnRestore = true
    }

    @discardableResult
    func recover(_ navigation: ReaderPositionSession.Navigation, rebuildEPUB: Bool = false) -> Task<Void, Never>? {
        positions.recover(navigation)
        if rebuildEPUB { rebuildOnRestore = true }
        renderer.epub?.cancelNavigation()
        return schedule()
    }

    @discardableResult
    func schedule() -> Task<Void, Never>? {
        guard canRestore() else { return nil }
        return positions.restore { [weak self] checkpoint, revision in
            guard let self else { return }
            do {
                try await self.restore(checkpoint, revision: revision)
            } catch is CancellationError {
                // Keep the checkpoint for the next foreground/layout completion.
            } catch {
                guard self.isCurrent(revision) else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func savePendingLocation() {
        guard canProtect(), positions.activity == .idle else { return }
        do { try positions.savePendingLocation() }
        catch { onEvent(.checkpointSaveFailed(error)) }
    }

    private func isCurrent(_ revision: Int) -> Bool {
        positions.isCurrent(revision) && canRestore()
    }

    private func restore(_ checkpoint: Checkpoint, revision: Int) async throws {
        guard isCurrent(revision) else { throw CancellationError() }
        error = nil
        let epub: EPUBReader?
        var presented: EPUBReader.Snapshot?
        if let previous = renderer.epub {
            if rebuildOnRestore || previous.needsNavigationReplacement { try renderer.rebuildEPUB(at: checkpoint.locator) }
            guard let current = renderer.epub, let location = checkpoint.locator else {
                throw AppFailure("Couldn’t read the last reading position.")
            }
            epub = current
            presented = try await current.move(to: .checkpoint(location, pointer: checkpoint.position?.xpointer)) {
                self.isCurrent(revision) && self.renderer.epub === current
            }
        } else {
            epub = nil
            if let saved = checkpoint.pdf, let pdf = renderer.pdf {
                _ = try await pdf.move(to: .checkpoint(saved)) {
                    self.isCurrent(revision) && self.renderer.pdf === pdf
                }
                guard renderer.pdf === pdf else { throw CancellationError() }
            }
        }
        guard isCurrent(revision), renderer.epub === epub else { throw CancellationError() }
        let locator = presented?.locator ?? epub?.currentLocation
        var checkedPointer = false
        if let epub, let locator,
           var position = checkpoint.position, position.xpointer == nil {
            let captured: EPUBReader.Snapshot?
            if let presented { captured = presented }
            else {
                captured = try? await epub.capture(.movement(locator), fallbackProgression: position.progression) {
                    self.isCurrent(revision) && self.renderer.epub === epub
                }
            }
            position.xpointer = captured?.position.xpointer
            guard isCurrent(revision), renderer.epub === epub else { throw CancellationError() }
            if position.xpointer != nil { try positions.commit(position, from: .checkpoint) }
            checkedPointer = true
        }
        rebuildOnRestore = false
        onEvent(.restored(checkpoint.position, checkedPointer: checkedPointer))
        positions.finishRestoration(at: locator)
    }
}
