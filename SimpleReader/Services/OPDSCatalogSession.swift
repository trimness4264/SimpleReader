import Foundation
import Observation

/// Owns the request lifecycle and accumulated results for one catalog destination.
@available(macOS 14, *)
@Observable @MainActor final class OPDSCatalogSession {
    private enum Request {
        case initialPage
        case search(link: OPDSLink, query: String)
        case nextPage(URL)
    }

    private(set) var catalog: OPDSCatalog?
    var error: String?
    var canSearch: Bool { searchLink != nil }
    var isLoading: Bool { loadTask != nil }

    let server: OPDSServer
    private let initialURL: URL
    private let client: OPDSClient
    private let accounts: AccountSettings
    private var searchLink: OPDSLink?
    @ObservationIgnored private var visited: Set<URL> = []
    @ObservationIgnored private var pendingRequest: Request?
    private var loadTask: Task<Void, Never>?

    init(server: OPDSServer, url: URL, client: OPDSClient, accounts: AccountSettings) {
        self.server = server
        initialURL = url
        self.client = client
        self.accounts = accounts
    }

    func resume() {
        guard !isLoading else { return }
        if let pendingRequest {
            start(pendingRequest)
        } else if catalog == nil {
            start(.initialPage)
        }
    }

    func search(_ query: String) {
        guard let searchLink else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start(.initialPage)
        } else {
            start(.search(link: searchLink, query: query))
        }
    }

    func loadNextPage() {
        guard !isLoading, let next = catalog?.next else { return }
        guard !visited.contains(next) else {
            error = AppFailure("The server returned a repeated pagination link.").localizedDescription
            return
        }
        start(.nextPage(next))
    }

    // Keep the pending request so the same destination can resume it on return.
    func pause() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func start(_ request: Request) {
        loadTask?.cancel()
        pendingRequest = request
        error = nil
        loadTask = Task { [weak self] in
            await self?.load(request)
        }
    }

    private func load(_ request: Request) async {
        defer {
            if !Task.isCancelled {
                pendingRequest = nil
                loadTask = nil
            }
        }
        do {
            try Task.checkCancellation()
            let credentials = try accounts.credentials(for: server)
            let url: URL
            switch request {
            case .initialPage:
                url = initialURL
            case .search(let link, let query):
                url = try await client.searchURL(link: link, query: query, credentials: credentials)
                try Task.checkCancellation()
            case .nextPage(let next):
                url = next
            }
            var page = try await client.load(url, credentials: credentials)
            try Task.checkCancellation()
            if case .nextPage = request, let previous = catalog {
                let existingIDs = Set(previous.entries.map(\.id))
                page.entries = previous.entries + page.entries.filter { !existingIDs.contains($0.id) }
                page.title = previous.title
            } else {
                visited.removeAll()
                searchLink = page.search ?? searchLink
            }
            visited.insert(url)
            catalog = page
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }
}
