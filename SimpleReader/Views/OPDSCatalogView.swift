import SwiftUI

struct CatalogView: View {
    let server: OPDSServer
    let url: URL
    let environment: AppEnvironment
    @State private var session: OPDSCatalogSession?
    @State private var query = ""

    var body: some View {
        ZStack {
            if let session {
                catalogContent(session)
            } else {
                ProgressView("Loading…")
            }
        }
        .navigationTitle(session?.catalog?.title ?? server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                DownloadsToolbarButton(manager: environment.downloads, environment: environment, alwaysVisible: true)
            }
        }
        .onAppear {
            if session == nil {
                session = OPDSCatalogSession(server: server, url: url, client: environment.opds, accounts: environment.accounts)
            }
            session?.resume()
        }
        .onDisappear {
            session?.pause()
        }
    }

    private func catalogContent(_ session: OPDSCatalogSession) -> some View {
        @Bindable var session = session
        return VStack(spacing: 0) {
            if session.canSearch {
                HStack {
                    TextField("Search library", text: $query)
                        .submitLabel(.search)
                        .onSubmit { session.search(query) }
                    Button("Search") { session.search(query) }
                }
                .padding()
                .background(Color(uiColor: .secondarySystemBackground))
            }
            List {
                ForEach(session.catalog?.entries ?? []) { entry in
                    let route: OPDSRoute = if let navigation = entry.navigation, entry.downloads.isEmpty {
                        .catalog(serverID: session.server.id, url: navigation.url)
                    } else {
                        .entry(.init(server: session.server, entry: entry))
                    }
                    NavigationLink(value: route) {
                        CatalogRow(entry: entry, http: environment.http) {
                            try environment.accounts.credentials(for: session.server)
                        }
                    }
                }
                if session.catalog?.next != nil {
                    Button("Load Next Page") { session.loadNextPage() }
                        .disabled(session.isLoading)
                }
                if session.isLoading {
                    ProgressView("Loading…")
                } else if let catalog = session.catalog {
                    if catalog.entries.isEmpty {
                        Text("This catalog has no books").foregroundColor(.secondary)
                    }
                } else {
                    Button("Reload") { session.resume() }
                }
            }
        }
        .errorAlert($session.error)
    }
}

private struct CatalogRow: View {
    let entry: OPDSEntry
    let http: HTTPClient
    let credentials: () throws -> ServerCredentials
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            if entry.cover != nil {
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFit()
                    } else {
                        Image(systemName: "book.closed").foregroundColor(.secondary)
                    }
                }
                .frame(width: 40, height: 56)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                if !entry.author.isEmpty {
                    Text(entry.author).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .task(id: entry.cover) {
            guard let url = entry.cover else { return }
            do {
                let request = try http.request(url, credentials: credentials())
                let (data, _) = try await http.data(request)
                cover = UIImage(data: data)
            } catch { /* Optional artwork must not block browsing. */ }
        }
    }
}
