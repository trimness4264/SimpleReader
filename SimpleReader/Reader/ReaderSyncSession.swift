import Foundation
import Observation

struct SyncPrompt: Identifiable {
    enum Kind { case conflict, approximate }
    enum Response { case useServer, uploadLocal, keepLocal }
    let id = UUID()
    let kind: Kind
    let remote: RemoteProgress
    let revision: Int
}

/// Coordinates progress checks and remote position offers for one open reader.
@Observable @MainActor final class ReaderSyncSession {
    enum Availability {
        case unavailable, restoring, inactive, reading(isScrolling: Bool)
    }

    enum Request {
        case opening, manual, uploadLocal, leaving
    }

    struct RemoteMoveFailure {
        let error: Error
        let canApproximate: Bool
    }

    private(set) var prompt: SyncPrompt?
    private(set) var error: String?
    private var notice: String?
    var message: String? { error ?? notice }

    private let bookID: UUID
    private let coordinator: SyncCoordinator
    private let positions: ReaderPositionSession
    private let availability: @MainActor () -> Availability
    private let flush: @MainActor () async -> Void
    private let move: @MainActor (RemoteProgress, Bool, @MainActor (RemoteMoveFailure) -> Void) async -> Void
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var isOpeningCheckPending = false
    @ObservationIgnored private var offeredApproximateFingerprint: String?

    init(bookID: UUID, coordinator: SyncCoordinator, positions: ReaderPositionSession,
         availability: @escaping @MainActor () -> Availability, flush: @escaping @MainActor () async -> Void,
         move: @escaping @MainActor (RemoteProgress, Bool, @MainActor (RemoteMoveFailure) -> Void) async -> Void) {
        self.bookID = bookID
        self.coordinator = coordinator
        self.positions = positions
        self.availability = availability
        self.flush = flush
        self.move = move
    }

    func checkOnOpen() async {
        isOpeningCheckPending = true
        await resumeOpeningCheck()
    }

    func discardOpeningCheck() {
        isOpeningCheckPending = false
    }

    func scheduleOpeningCheck() {
        guard isOpeningCheckPending else { return }
        Task { [weak self] in await self?.resumeOpeningCheck() }
    }

    func resumeOpeningCheck() async {
        if !Task.isCancelled, isOpeningCheckPending, canStart(.opening) {
            await run(.opening)
            if !Task.isCancelled { isOpeningCheckPending = false }
        }
        if Task.isCancelled { scheduleOpeningCheck() }
    }

    func synchronize(_ request: Request) async {
        guard !Task.isCancelled, canStart(request) else { return }
        let coversOpeningCheck = request == .manual && isOpeningCheckPending
        await run(request)
        if coversOpeningCheck && !Task.isCancelled {
            isOpeningCheckPending = false
        }
        await resumeOpeningCheck()
    }

    private func canStart(_ request: Request) -> Bool {
        guard !inFlight, prompt == nil else { return false }
        let availability = availability()
        switch (request, availability) {
        case (_, .unavailable): return false
        case (.leaving, _), (.uploadLocal, .inactive), (_, .reading): return true
        default: return false
        }
    }

    private func run(_ request: Request) async {
        inFlight = true
        defer { inFlight = false }
        let revision = positions.movementRevision
        notice = nil
        error = nil
        do {
            // Save the latest page before the coordinator takes a snapshot.
            if request != .opening && request != .leaving { await flush() }
            if let error = positions.persistenceError { throw error }
            let outcome = try await coordinator.synchronize(bookID, preferLocal: request == .uploadLocal)
            try Task.checkCancellation()
            switch outcome {
            case .idle: break
            case .conflict(let remote), .remote(let remote):
                // A response may arrive before a newer position has reached the store.
                guard request != .leaving, canApplyRemote(revision: revision) else {
                    notice = String(localized: "Your current reading position was kept. Sync again later.")
                    return
                }
                if case .conflict = outcome {
                    prompt = SyncPrompt(kind: .conflict, remote: remote, revision: revision)
                } else if request != .manual && remote.fingerprint == offeredApproximateFingerprint {
                    notice = String(localized: "Couldn’t resolve the exact remote position. Local progress was kept.")
                } else {
                    await receive(remote, revision: revision)
                }
            }
        } catch is CancellationError {
            // The caller keeps the opening check pending if its task was cancelled.
        } catch {
            if !Task.isCancelled { self.error = String(localized: "Sync failed: \(error.localizedDescription)") }
        }
    }

    func respond(to offer: SyncPrompt, with response: SyncPrompt.Response) async {
        guard prompt?.id == offer.id else { return }
        prompt = nil
        switch response {
        case .useServer:
            await receive(offer.remote, approximate: offer.kind == .approximate, revision: offer.revision)
        case .uploadLocal:
            await synchronize(.uploadLocal)
        case .keepLocal:
            break
        }
        await resumeOpeningCheck()
    }

    private func receive(_ remote: RemoteProgress, approximate: Bool = false, revision: Int) async {
        guard canApplyRemote(revision: revision) else { return }
        notice = nil
        error = nil
        await move(remote, approximate) { failure in
            error = String(localized: "Sync failed: \(failure.error.localizedDescription)")
            if failure.canApproximate && !approximate {
                offeredApproximateFingerprint = remote.fingerprint
                prompt = SyncPrompt(kind: .approximate, remote: remote, revision: positions.movementRevision)
            }
        }
    }

    private func canApplyRemote(revision: Int) -> Bool {
        guard case .reading(isScrolling: false) = availability() else { return false }
        return !Task.isCancelled && positions.movementRevision == revision
    }
}
