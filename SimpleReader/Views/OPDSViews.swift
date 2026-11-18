import SwiftUI

enum OPDSRoute: Hashable {
    case catalog(serverID: UUID, url: URL)
    case entry(EntrySelection)

    struct EntrySelection: Hashable {
        let server: OPDSServer
        let entry: OPDSEntry

        // Keep the tapped result with its route. Only its identity participates in path comparisons.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.server.id == rhs.server.id && lhs.entry.id == rhs.entry.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(server.id)
            hasher.combine(entry.id)
        }
    }
}

struct ServersView: View {
    let environment: AppEnvironment
    @ObservedObject private var store: LibraryStore
    @State private var path: [OPDSRoute] = []
    @State private var editing: OPDSServer?
    @State private var adding = false
    @State private var error: String?
    init(environment: AppEnvironment) { self.environment = environment; store = environment.store }
    var body: some View {
        NavigationStack(path: $path) {
            serverList.navigationDestination(for: OPDSRoute.self) { route in
                destination(for: route)
            }
        }
    }

    private var serverList: some View {
        List {
            if store.settings.servers.isEmpty {
                Section { Text("Enter your Calibre OPDS address, for example http://192.168.1.10:8080/opds.").foregroundColor(.secondary); Button("Add Server") { adding = true } }
            }
            ForEach(store.settings.servers) { server in
                NavigationLink(value: OPDSRoute.catalog(serverID: server.id, url: server.url)) {
                    VStack(alignment: .leading, spacing: 5) { Text(server.name); Text(server.url.absoluteString).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                }
                .swipeActions { Button("Edit") { editing = server }.tint(.accentColor); Button(role: .destructive) { delete(server) } label: { Label("Delete", systemImage: "trash") } }
            }
        }.navigationTitle("Online Library")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                DownloadsToolbarButton(manager: environment.downloads, environment: environment, alwaysVisible: true)
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add Server")
            }
        }
        .sheet(isPresented: $adding) { ServerEditor(accounts: environment.accounts, server: nil) }
        .sheet(item: $editing) { ServerEditor(accounts: environment.accounts, server: $0) }
        .errorAlert($error)
    }

    @ViewBuilder private func destination(for route: OPDSRoute) -> some View {
        switch route {
        case .catalog(let serverID, let url):
            if let server = store.settings.servers.first(where: { $0.id == serverID }) {
                CatalogView(server: server, url: url, environment: environment)
            } else {
                ContentUnavailableView("Couldn’t Complete Action", systemImage: "exclamationmark.circle")
            }
        case .entry(let selection):
            EntryView(entry: selection.entry, server: selection.server, environment: environment)
        }
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
        NavigationStack {
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
        }.task { if let server = server { do { password = try accounts.password(for: server) } catch { self.error = error.localizedDescription } } }.errorAlert($error)
    }
    private func save() {
        do {
            try accounts.saveServer(server, name: name, address: address, username: username, password: password)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct EntryView: View {
    let entry: OPDSEntry
    let server: OPDSServer
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
                    EntryDownloadView(title: entry.title, link: link, server: server, environment: environment)
                }
                if entry.downloads.isEmpty { Text("No EPUB or PDF downloads available. DRM-protected books are unsupported.").foregroundColor(.secondary) }
            }
        }.navigationTitle("Book Details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { DownloadsToolbarButton(manager: environment.downloads, environment: environment, alwaysVisible: true) } }
    }
}

private struct EntryDownloadView: View {
    let title: String
    let link: OPDSLink
    let server: OPDSServer
    let environment: AppEnvironment
    @ObservedObject private var manager: DownloadManager
    @State private var reading: Book?
    @State private var error: String?

    init(title: String, link: OPDSLink, server: OPDSServer, environment: AppEnvironment) {
        self.title = title; self.link = link; self.server = server; self.environment = environment
        manager = environment.downloads
    }

    private var job: DownloadJob? { manager.job(for: link) }
    private var format: String { link.type == "application/pdf" ? "PDF" : "EPUB" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = job {
                let actions = manager.actions(for: job)
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
                    if actions.canCancel { Button("Cancel Download", role: .destructive) { manager.cancel(job.id) } }
                case .importing:
                    ProgressView("Adding \(format) to library…")
                case .finished:
                    if let id = actions.bookID {
                        Label("\(format) added to library", systemImage: "checkmark.circle").foregroundColor(.secondary)
                        Button { reading = environment.store.book(id) } label: { Label("Read \(format)", systemImage: "book") }
                    } else {
                        Text("\(format) removed from library").foregroundColor(.secondary)
                        if actions.canRetry { downloadButton }
                    }
                case .failed, .cancelled:
                    Text(job.state == .failed ? "\(format) download failed" : "\(format) download canceled").foregroundColor(.secondary)
                    if let message = job.error { Text(message).font(.caption).foregroundColor(.red) }
                    if actions.canRetry {
                        Button { manager.retry(job.id) } label: { Label("Download \(format) Again", systemImage: "arrow.clockwise") }
                    }
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
            do { manager.enqueue(title: title, link: link, credentials: try environment.accounts.credentials(for: server)) }
            catch { self.error = error.localizedDescription }
        } label: { Label("Download \(format)", systemImage: "arrow.down.circle") }
    }
}
