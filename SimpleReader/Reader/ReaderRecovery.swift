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
    @ObservationIgnored private var rebuildOnRetry = false
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
        rebuildOnRetry = true
    }

    func recover(_ navigation: ReaderPositionSession.Navigation) {
        positions.recover(navigation)
        renderer.epub?.cancelNavigation()
        schedule()
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
        if renderer.epub != nil {
            if rebuildOnRetry { try renderer.rebuildEPUB(at: checkpoint.locator) }
            guard let current = renderer.epub, let location = checkpoint.locator else {
                throw AppFailure("Couldn’t read the last reading position.")
            }
            epub = current
            try await current.move(to: .checkpoint(location, pointer: checkpoint.position?.xpointer)) {
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
        var checkedPointer = false
        if let epub, let locator = epub.currentLocation,
           var position = checkpoint.position, position.xpointer == nil {
            let captured = try? await epub.capture(.movement(locator), fallbackProgression: position.progression)
            position.xpointer = captured?.position.xpointer
            guard isCurrent(revision), renderer.epub === epub else { throw CancellationError() }
            if position.xpointer != nil { try positions.commit(position, from: .checkpoint) }
            checkedPointer = true
        }
        rebuildOnRetry = false
        onEvent(.restored(checkpoint.position, checkedPointer: checkedPointer))
        positions.finishRestoration(at: epub?.currentLocation)
    }
}
