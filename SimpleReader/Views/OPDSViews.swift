import SwiftUI

struct ServersView: View {
    let environment: AppEnvironment
    @ObservedObject private var store: LibraryStore
    @State private var editing: OPDSServer?
    @State private var adding = false
    @State private var error: String?
    init(environment: AppEnvironment) { self.environment = environment; store = environment.store }
    var body: some View {
        List {
            if store.settings.servers.isEmpty {
                Section { Text("Enter your Calibre OPDS address, for example http://192.168.1.10:8080/opds.").foregroundColor(.secondary); Button("Add Server") { adding = true } }
            }
            ForEach(store.settings.servers) { server in
                NavigationLink(destination: CatalogView(server: server, url: server.url, environment: environment)) {
                    VStack(alignment: .leading, spacing: 5) { Text(server.name); Text(server.url.absoluteString).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                }
                .swipeActions { Button("Edit") { editing = server }.tint(.accentColor); Button(role: .destructive) { delete(server) } label: { Label("Delete", systemImage: "trash") } }
            }
        }.navigationTitle("Online Library")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                DownloadsToolbarButton(manager: environment.downloads, alwaysVisible: true)
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Server")
            }
        }
        .sheet(isPresented: $adding) { ServerEditor(accounts: environment.accounts, server: nil) }
        .sheet(item: $editing) { ServerEditor(accounts: environment.accounts, server: $0) }
        .errorAlert($error)
    }
    private func delete(_ server: OPDSServer) {
        do { try environment.accounts.deleteServer(server) }
        catch { self.error = error.localizedDescription }
    }
}
struct ServerEditor: View {
    let accounts: AccountSettings
    let server: OPDSServer?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var username: String
    @State private var password = ""
    @State private var error: String?
    init(accounts: AccountSettings, server: OPDSServer?) {
        self.accounts = accounts; self.server = server
        _name = State(initialValue: server?.name ?? "Calibre")
        _address = State(initialValue: server?.url.absoluteString ?? "")
        _username = State(initialValue: server?.username ?? "")
    }
    var body: some View {
        NavigationView {
            Form {
                TextField("Name", text: $name)
                TextField("OPDS Address", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Section(header: Text("Basic Authentication (Optional)")) {
                    TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Text("Local HTTP connections send credentials in plain text. Use HTTPS on public networks.").font(.caption).foregroundColor(.secondary)
            }.navigationTitle(server == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.isEmpty) }
            }
        }.navigationViewStyle(.stack).task { if let server = server { do { password = try accounts.password(for: server) } catch { self.error = error.localizedDescription } } }.errorAlert($error)
    }
    private func save() {
        do {
            try accounts.saveServer(server, name: name, address: address, username: username, password: password)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor final class CatalogModel: ObservableObject {
    @Published var catalog: OPDSCatalog?
    @Published var loading = false
    @Published var error: String?
    @Published var query = ""
    let server: OPDSServer
    let initialURL: URL
    let client: OPDSClient
    private let accounts: AccountSettings
    private var searchLink: OPDSLink?
    private var visited: Set<URL> = []
    init(server: OPDSServer, url: URL, client: OPDSClient, accounts: AccountSettings) {
        self.server = server; initialURL = url; self.client = client; self.accounts = accounts
    }
    func credentials() throws -> ServerCredentials { try accounts.credentials(for: server) }
    var canSearch: Bool { searchLink != nil }
    func load(url: URL? = nil, append: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let target = url ?? initialURL
            if append && visited.contains(target) { throw AppFailure("The server returned a repeated pagination link.") }
            var loaded = try await client.load(target, credentials: credentials())
            if append, let previous = catalog {
                let ids = Set(previous.entries.map(\.id)); loaded.entries = previous.entries + loaded.entries.filter { !ids.contains($0.id) }
                loaded.title = previous.title
            } else { visited.removeAll(); searchLink = loaded.search ?? searchLink }
            visited.insert(target); catalog = loaded
        } catch { self.error = error.localizedDescription }
    }
    func search() async {
        guard let link = searchLink else { return }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { await load(); return }
        do { let url = try await client.searchURL(link: link, query: query, credentials: credentials()); await load(url: url) }
        catch { self.error = error.localizedDescription }
    }
}
struct CatalogView: View {
    let environment: AppEnvironment
    @StateObject private var model: CatalogModel
    init(server: OPDSServer, url: URL, environment: AppEnvironment) {
        self.environment = environment; _model = StateObject(wrappedValue: CatalogModel(server: server, url: url, client: environment.opds, accounts: environment.accounts))
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.canSearch {
                HStack { TextField("Search library", text: $model.query).submitLabel(.search).onSubmit { Task { await model.search() } }; Button("Search") { Task { await model.search() } }.disabled(model.loading) }.padding().background(Color(UIColor.secondarySystemBackground))
            }
            List {
                ForEach(model.catalog?.entries ?? []) { entry in
                    if let navigation = entry.navigation, entry.downloads.isEmpty {
                        NavigationLink(destination: CatalogView(server: model.server, url: navigation.url, environment: environment)) { CatalogRow(entry: entry, model: model, http: environment.http) }
                    } else {
                        NavigationLink(destination: EntryView(entry: entry, model: model, environment: environment)) { CatalogRow(entry: entry, model: model, http: environment.http) }
                    }
                }
                if let next = model.catalog?.next { Button("Load Next Page") { Task { await model.load(url: next, append: true) } }.disabled(model.loading) }
                if model.loading { ProgressView("Loading…") }
                if !model.loading && model.catalog?.entries.isEmpty == true { Text("This catalog has no books").foregroundColor(.secondary) }
                if model.catalog == nil && !model.loading { Button("Reload") { Task { await model.load() } } }
            }
        }.navigationTitle(model.catalog?.title ?? model.server.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { DownloadsToolbarButton(manager: environment.downloads, alwaysVisible: true) } }
        .task { if model.catalog == nil { await model.load() } }.errorAlert($model.error)
    }
}
private struct CatalogRow: View {
    let entry: OPDSEntry
    let model: CatalogModel
    let http: HTTPClient
    @State private var cover: UIImage?
    var body: some View {
        HStack(spacing: 14) {
            if entry.cover != nil {
                Group { if let cover = cover { Image(uiImage: cover).resizable().scaledToFit() } else { Image(systemName: "book.closed").foregroundColor(.secondary) } }.frame(width: 40, height: 56)
            }
            VStack(alignment: .leading, spacing: 5) { Text(entry.title); if !entry.author.isEmpty { Text(entry.author).font(.caption).foregroundColor(.secondary) } }
        }.padding(.vertical, 4)
        .task(id: entry.cover) {
            guard let url = entry.cover else { return }
            do { let (data, _) = try await http.data(http.request(url, credentials: model.credentials())); cover = UIImage(data: data) } catch { /* Optional artwork must not block browsing. */ }
        }
    }
}
struct EntryView: View {
    let entry: OPDSEntry
    let model: CatalogModel
    let environment: AppEnvironment
    private var downloadLinks: [OPDSLink] {
        var seen = Set<OPDSLink>()
        return entry.downloads.filter { seen.insert($0).inserted }
    }
    var body: some View {
        List {
            Section { Text(entry.title).font(.title2); if !entry.author.isEmpty { Text(entry.author).foregroundColor(.secondary) }; if !entry.summary.isEmpty { Text(entry.summary) } }
            Section(header: Text("Download to This Device")) {
                ForEach(downloadLinks, id: \.self) { link in
                    EntryDownloadView(title: entry.title, link: link, model: model, environment: environment)
                }
                if entry.downloads.isEmpty { Text("No EPUB or PDF downloads available. DRM-protected books are unsupported.").foregroundColor(.secondary) }
            }
        }.navigationTitle("Book Details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { DownloadsToolbarButton(manager: environment.downloads, alwaysVisible: true) } }
    }
}

private struct EntryDownloadView: View {
    let title: String
    let link: OPDSLink
    let model: CatalogModel
    let environment: AppEnvironment
    @ObservedObject private var manager: DownloadManager
    @ObservedObject private var store: LibraryStore
    @State private var reading: Book?
    @State private var error: String?

    init(title: String, link: OPDSLink, model: CatalogModel, environment: AppEnvironment) {
        self.title = title; self.link = link; self.model = model; self.environment = environment
        manager = environment.downloads; store = environment.store
    }

    private var job: DownloadJob? { manager.job(for: link) }
    private var format: String { link.type == "application/pdf" ? "PDF" : "EPUB" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = job {
                switch job.state {
                case .queued, .downloading:
                    HStack {
                        Text(job.state == .queued ? "\(format) queued" : "Downloading \(format)")
                        Spacer()
                        if job.state == .downloading {
                            Text("\(Int(job.progress * 100))%").monospacedDigit().foregroundColor(.secondary)
                        }
                    }
                    if job.state == .downloading { ProgressView(value: job.progress).accessibilityLabel("\(format) download progress") }
                    Button("Cancel Download", role: .destructive) { manager.cancel(job.id) }
                case .importing:
                    ProgressView("Adding \(format) to library…")
                case .finished:
                    if let id = job.bookID, let book = store.book(id) {
                        Label("\(format) added to library", systemImage: "checkmark.circle").foregroundColor(.secondary)
                        Button { reading = book } label: { Label("Read \(format)", systemImage: "book") }
                    } else {
                        Text("\(format) removed from library").foregroundColor(.secondary)
                        downloadButton
                    }
                case .failed, .cancelled:
                    Text(job.state == .failed ? "\(format) download failed" : "\(format) download canceled").foregroundColor(.secondary)
                    if let message = job.error { Text(message).font(.caption).foregroundColor(.red) }
                    Button { manager.retry(job.id) } label: { Label("Download \(format) Again", systemImage: "arrow.clockwise") }
                }
            } else { downloadButton }
        }
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
        .errorAlert($error)
        .fullScreenCover(item: $reading) { book in ReaderView(bookID: book.id, environment: environment) }
    }

    private var downloadButton: some View {
        Button {
            do { manager.enqueue(title: title, link: link, credentials: try model.credentials()) }
            catch { self.error = error.localizedDescription }
        } label: { Label("Download \(format)", systemImage: "arrow.down.circle") }
    }
}
