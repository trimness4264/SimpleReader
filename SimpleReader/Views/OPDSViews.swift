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
                Section { Text("添加 Calibre 的 OPDS 地址，例如 http://192.168.1.10:8080/opds。").foregroundColor(.secondary); Button("添加服务器") { adding = true } }
            }
            ForEach(store.settings.servers) { server in
                NavigationLink(destination: CatalogView(server: server, url: server.url, environment: environment)) {
                    VStack(alignment: .leading, spacing: 5) { Text(server.name); Text(server.url.absoluteString).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                }
                .swipeActions { Button("编辑") { editing = server }.tint(.blue); Button(role: .destructive) { delete(server) } label: { Label("删除", systemImage: "trash") } }
            }
        }.navigationTitle("在线书库")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                DownloadsToolbarButton(manager: environment.downloads, alwaysVisible: true)
                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加服务器")
            }
        }
        .sheet(isPresented: $adding) { ServerEditor(store: store, server: nil) }
        .sheet(item: $editing) { ServerEditor(store: store, server: $0) }
        .errorAlert($error)
    }
    private func delete(_ server: OPDSServer) {
        do { var settings = store.settings; settings.servers.removeAll { $0.id == server.id }; try store.saveSettings(settings); KeychainService.delete("opds-\(server.id)") }
        catch { self.error = error.localizedDescription }
    }
}
struct ServerEditor: View {
    @ObservedObject var store: LibraryStore
    let server: OPDSServer?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address: String
    @State private var username: String
    @State private var password = ""
    @State private var error: String?
    init(store: LibraryStore, server: OPDSServer?) {
        self.store = store; self.server = server
        _name = State(initialValue: server?.name ?? "Calibre")
        _address = State(initialValue: server?.url.absoluteString ?? "")
        _username = State(initialValue: server?.username ?? "")
    }
    var body: some View {
        NavigationView {
            Form {
                TextField("名称", text: $name)
                TextField("OPDS 地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Section(header: Text("Basic Auth（可选）")) {
                    TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }
                Text("局域网 HTTP 会明文传输认证信息。公网请使用 HTTPS。").font(.caption).foregroundColor(.secondary)
            }.navigationTitle(server == nil ? "添加服务器" : "编辑服务器")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || address.isEmpty) }
            }
        }.navigationViewStyle(.stack).task { if let server = server { do { password = try KeychainService.read("opds-\(server.id)") } catch { self.error = error.localizedDescription } } }.errorAlert($error)
    }
    private func save() {
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw AppFailure("服务器地址无效") }
            try NetworkPolicy.validate(url)
            let record = OPDSServer(id: server?.id ?? UUID(), name: name, url: url, username: username)
            let key = "opds-\(record.id)"
            let old = try KeychainService.read(key)
            try KeychainService.save(password, key: key)
            do {
                var settings = store.settings
                if let index = settings.servers.firstIndex(where: { $0.id == record.id }) { settings.servers[index] = record } else { settings.servers.append(record) }
                try store.saveSettings(settings)
            } catch { try? KeychainService.save(old, key: key); throw error }
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
    private var searchLink: OPDSLink?
    private var visited: Set<URL> = []
    init(server: OPDSServer, url: URL, client: OPDSClient) { self.server = server; initialURL = url; self.client = client }
    func credentials() throws -> ServerCredentials { ServerCredentials(origin: server.url, username: server.username, password: try KeychainService.read("opds-\(server.id)")) }
    var canSearch: Bool { searchLink != nil }
    func load(url: URL? = nil, append: Bool = false) async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do {
            let target = url ?? initialURL
            if append && visited.contains(target) { throw AppFailure("服务器分页链接重复") }
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
        self.environment = environment; _model = StateObject(wrappedValue: CatalogModel(server: server, url: url, client: environment.opds))
    }
    var body: some View {
        VStack(spacing: 0) {
            if model.canSearch {
                HStack { TextField("搜索书库", text: $model.query).submitLabel(.search).onSubmit { Task { await model.search() } }; Button("搜索") { Task { await model.search() } }.disabled(model.loading) }.padding().background(Color(UIColor.secondarySystemBackground))
            }
            List {
                ForEach(model.catalog?.entries ?? []) { entry in
                    if let navigation = entry.navigation, entry.downloads.isEmpty {
                        NavigationLink(destination: CatalogView(server: model.server, url: navigation.url, environment: environment)) { CatalogRow(entry: entry, model: model, http: environment.http) }
                    } else {
                        NavigationLink(destination: EntryView(entry: entry, model: model, environment: environment)) { CatalogRow(entry: entry, model: model, http: environment.http) }
                    }
                }
                if let next = model.catalog?.next { Button("加载下一页") { Task { await model.load(url: next, append: true) } }.disabled(model.loading) }
                if model.loading { ProgressView("正在加载…") }
                if !model.loading && model.catalog?.entries.isEmpty == true { Text("这个目录没有图书").foregroundColor(.secondary) }
                if model.catalog == nil && !model.loading { Button("重新加载") { Task { await model.load() } } }
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
private struct EntryView: View {
    let entry: OPDSEntry
    let model: CatalogModel
    let environment: AppEnvironment
    @State private var error: String?
    @State private var queued = false
    var body: some View {
        List {
            Section { Text(entry.title).font(.title2); if !entry.author.isEmpty { Text(entry.author).foregroundColor(.secondary) }; if !entry.summary.isEmpty { Text(entry.summary) } }
            Section(header: Text("下载到本机")) {
                ForEach(Array(entry.downloads.enumerated()), id: \.offset) { _, link in
                    Button { do { environment.downloads.enqueue(title: entry.title, link: link, credentials: try model.credentials()); queued = true } catch { self.error = error.localizedDescription } } label: { Label(link.type == "application/pdf" ? "下载 PDF" : "下载 EPUB", systemImage: "arrow.down.circle") }
                }
                if entry.downloads.isEmpty { Text("没有可下载的 EPUB/PDF；DRM 图书暂不支持。").foregroundColor(.secondary) }
                if queued { Text("已加入下载队列，点右上角下载按钮查看进度。完成后会自动加入书库。").foregroundColor(.secondary) }
            }
        }.navigationTitle("图书详情").navigationBarTitleDisplayMode(.inline).errorAlert($error)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { DownloadsToolbarButton(manager: environment.downloads, alwaysVisible: true) } }
    }
}
