import Foundation
import ReadiumShared

/// Executes jumps and persists page turns once the container confirms their outcome.
@MainActor final class ReaderNavigation {
    enum Target {
        case progression(Double), link(Link), page(Int), checkpoint(ReaderPositionSession.Checkpoint)
    }

    enum Request {
        case jump(Target), returning(to: ReaderPositionSession.Checkpoint), remote(RemoteProgress, approximate: Bool)

        var isRemote: Bool {
            if case .remote = self { return true }
            return false
        }

        fileprivate var source: ReaderPositionSession.Source {
            if case .remote(let remote, _) = self { return .remote(remote) }
            return .movement
        }

        fileprivate var history: ReaderPositionSession.History {
            switch self {
            case .jump: return .rememberOrigin
            case .returning: return .returning
            case .remote: return .unchanged
            }
        }
    }

    enum Event {
        case originSaveFailed(Error)
        case committed(ReadingPosition)
        case rolledBack(to: ReadingPosition?, error: Error)
    }

    enum PageTurnEvent {
        case committed(ReadingPosition)
        case failed(Error)
        case cancelTransition(Error)
        case discarded
    }

    private typealias Destination = (position: ReadingPosition, locator: Locator?)
    private let renderer: ReaderRenderer
    private let positions: ReaderPositionSession
    private let recovery: ReaderRecovery

    init(renderer: ReaderRenderer, positions: ReaderPositionSession, recovery: ReaderRecovery) {
        self.renderer = renderer
        self.positions = positions
        self.recovery = recovery
    }

    func pageTurnDirection(forward: Bool) -> Bool {
        renderer.epub?.towardLeft(forward: forward) ?? forward
    }

    func canBeginPageTurn(isGesture: Bool) -> Bool {
        guard positions.activity == .idle else { return false }
        if let epub = renderer.epub { return epub.canBeginPageTurn(isGesture: isGesture) }
        return !isGesture && renderer.pdf != nil
    }

    func beginPageTurn(onSaveFailure: (Error) -> Void) {
        guard canBeginPageTurn(isGesture: false) else { return }
        _ = begin(.pageTurn, onSaveFailure: onSaveFailure)
    }

    func movePage(towardLeft: Bool, isActive: @MainActor () -> Bool) async throws -> Bool {
        guard let navigation = positions.pageTurn, owns(navigation, isActive: isActive) else { return false }
        if let epub = renderer.epub {
            return try await epub.movePage(towardLeft: towardLeft) {
                self.owns(navigation, isActive: isActive) && self.renderer.epub === epub
            }
        }
        guard let pdf = renderer.pdf else { return false }
        return try await pdf.turn(forward: towardLeft) {
            self.owns(navigation, isActive: isActive) && self.renderer.pdf === pdf
        }
    }

    func finishPageTurn(_ outcome: PageTurnOutcome, fallbackProgression: Double, isActive: @MainActor () -> Bool,
                        onEvent: @MainActor (PageTurnEvent) -> Void) async {
        guard let navigation = positions.pageTurn, owns(navigation, isActive: isActive) else { return }
        defer { positions.finishNavigation(navigation) }
        switch outcome {
        case .unchanged:
            positions.finishNavigation(navigation)
            onEvent(.discarded)
            return
        case .restoreOrigin(let error):
            if let error { onEvent(.failed(error)) }
            recovery.recover(navigation)
            return
        case .settled:
            break
        }

        do {
            let destination: Destination
            if let pdf = renderer.pdf, let position = pdf.position() {
                destination = (position, nil)
            } else if let epub = renderer.epub,
                      let captured = try await epub.capture(.settledPage, fallbackProgression: fallbackProgression) {
                guard owns(navigation, isActive: isActive), renderer.epub === epub else { return }
                destination = (captured.position, captured.locator)
            } else {
                recovery.recover(navigation)
                return
            }
            try positions.commitNavigation(navigation, position: destination.position, from: .movement, locator: destination.locator)
            onEvent(.committed(destination.position))
        } catch {
            guard owns(navigation, isActive: isActive) else { return }
            if error is CancellationError {
                recovery.recover(navigation)
            } else if renderer.epub != nil {
                // Keep Readium usable when the displayed position cannot be recorded.
                positions.finishNavigation(navigation)
                onEvent(.cancelTransition(error))
            } else {
                onEvent(.failed(error))
                recovery.recover(navigation)
            }
        }
    }

    /// Returns whether to resume pending location capture after discarding an unchanged turn.
    func cancelPageTurn(needsRestoration: Bool) -> Bool {
        guard let navigation = positions.pageTurn else { return false }
        if needsRestoration {
            recovery.recover(navigation)
            return false
        }
        positions.finishNavigation(navigation)
        return true
    }

    /// On close, the saved origin is authoritative even if the renderer has moved.
    func abandonPageTurnForClose() -> Bool {
        guard let navigation = positions.pageTurn else { return false }
        positions.finishNavigation(navigation)
        return true
    }

    private func owns(_ navigation: ReaderPositionSession.Navigation, isActive: @MainActor () -> Bool) -> Bool {
        isActive() && positions.origin(of: navigation) != nil
    }

    @discardableResult
    func perform(
        _ request: Request,
        fallbackProgression: Double,
        isActive: @MainActor () -> Bool,
        isStillVisible: @MainActor () -> Bool,
        onEvent: @MainActor (Event) -> Void
    ) async -> Bool {
        guard isActive(), positions.activity == .idle, !renderer.container.isTurningPage else {
            return false
        }
        let epub = renderer.epub
        let pdf = renderer.pdf
        let navigation = begin(.jump) { onEvent(.originSaveFailed($0)) }
        // Publish outcomes before unlocking the transaction and waking pending sync.
        defer { positions.finishNavigation(navigation) }
        func ownsRenderer() -> Bool {
            owns(navigation, isActive: isActive) && renderer.epub === epub && renderer.pdf === pdf
        }
        func isCurrent() -> Bool {
            ownsRenderer() && !Task.isCancelled && (!request.isRemote || isStillVisible())
        }
        do {
            if let epub, let origin = positions.origin(of: navigation), let locator = origin.locator {
                let captured = try await epub.capture(.origin(locator, saved: origin.position), fallbackProgression: fallbackProgression)
                guard isCurrent() else { throw CancellationError() }
                if let captured {
                    positions.refineOrigin(.init(position: captured.position, locator: captured.locator, pdf: nil), for: navigation)
                }
            }
            let destination = try await move(request, fallbackProgression: fallbackProgression, isCurrent: isCurrent)
            guard isCurrent() else { throw CancellationError() }
            try positions.commitNavigation(navigation, position: destination.position, from: request.source,
                locator: destination.locator, history: request.history)
            onEvent(.committed(destination.position))
            return true
        } catch {
            guard ownsRenderer(), let origin = positions.origin(of: navigation) else { return false }
            if isCurrent(), !(error is CancellationError) {
                do {
                    _ = try await move(to: .checkpoint(origin), isCurrent: isCurrent)
                    guard isCurrent() else { throw CancellationError() }
                    onEvent(.rolledBack(to: origin.position, error: error))
                    return false
                } catch {
                    guard ownsRenderer() else { return false }
                }
            }
            recovery.recover(navigation)
            return false
        }
    }

    private func begin(_ kind: ReaderPositionSession.Navigation.Kind, onSaveFailure: (Error) -> Void) -> ReaderPositionSession.Navigation {
        do { try positions.savePendingLocation() }
        catch { onSaveFailure(error) }
        // A settled turn can record its locator before Readium publishes the location change.
        let locator = kind == .pageTurn
            ? positions.latestLocator ?? renderer.epub?.currentLocation
            : renderer.epub?.currentLocation ?? positions.latestLocator
        let origin = ReaderPositionSession.Checkpoint(position: positions.current, locator: locator, pdf: renderer.pdf?.checkpoint(at: nil))
        return positions.beginNavigation(kind, from: origin)
    }

    private func move(_ request: Request, fallbackProgression: Double, isCurrent: @MainActor () -> Bool) async throws -> Destination {
        let target: Target
        switch request {
        case .jump(let selection): target = selection
        case .returning(let previous): target = .checkpoint(previous)
        case .remote(let remote, let approximate):
            if let epub = renderer.epub {
                let captured = try await epub.remoteSnapshot(remote, approximate: approximate, isCurrent: isCurrent)
                return (captured.position, captured.locator)
            }
            guard let raw = remote.progress, let page = Int(raw), let pdf = renderer.pdf, (1...pdf.pageCount).contains(page) else {
                throw AppFailure("The remote PDF page number is outside this book’s range.")
            }
            return (try await pdf.move(to: .page(page - 1), isCurrent: isCurrent), nil)
        }
        let epub = renderer.epub
        let pdfPosition = try await move(to: target, isCurrent: isCurrent)
        guard isCurrent() else { throw CancellationError() }
        if let epub, let captured = try await epub.capture(.navigation, fallbackProgression: fallbackProgression) {
            return (captured.position, captured.locator)
        }
        if let pdfPosition { return (pdfPosition, nil) }
        throw AppFailure("Couldn’t jump to the selected position.")
    }

    private func move(to target: Target, isCurrent: @MainActor () -> Bool) async throws -> ReadingPosition? {
        if let epub = renderer.epub {
            switch target {
            case .progression(let value): try await epub.move(to: .progression(value), isCurrent: isCurrent)
            case .link(let link): try await epub.move(to: .link(link), isCurrent: isCurrent)
            case .checkpoint(let saved):
                try await epub.move(to: .checkpoint(saved.locator, pointer: saved.position?.xpointer), isCurrent: isCurrent)
            case .page: throw AppFailure("Couldn’t jump to the selected position.")
            }
            return nil
        }
        if let pdf = renderer.pdf {
            switch target {
            case .page(let index): return try await pdf.move(to: .page(index), isCurrent: isCurrent)
            case .checkpoint(let saved):
                guard let checkpoint = saved.pdf else { throw AppFailure("Couldn’t return to the previous position.") }
                return try await pdf.move(to: .checkpoint(checkpoint), isCurrent: isCurrent)
            default: break
            }
        }
        throw AppFailure("Couldn’t jump to the selected position.")
    }
}
