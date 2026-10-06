import SwiftUI

private struct ReaderSurface: UIViewControllerRepresentable {
    let session: ReaderSession
    func makeUIViewController(context: Context) -> UIViewController { session.container }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}
struct ReaderView: View {
    @StateObject private var session: ReaderSession
    @ObservedObject private var store: LibraryStore
    @ObservedObject private var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var showContents = false
    @State private var showPreferences = false
    @State private var closing = false
    init(bookID: UUID, environment: AppEnvironment) {
        store = environment.store; sync = environment.sync
        _session = StateObject(wrappedValue: ReaderSession(bookID: bookID, store: environment.store, readium: environment.readium, sync: environment.sync))
    }
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ReaderSurface(session: session)
                    .overlay { if !session.ready && session.error == nil { ProgressView("正在打开…") } }
                if let warning = session.bridgeWarning { Text(warning).font(.caption).foregroundColor(.orange).padding(8) }
                HStack {
                    Button { Task { await session.turn(forward: false) } } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一页")
                    Spacer()
                    VStack(spacing: 3) { Text("\(Int(session.progression*100))%").font(.caption.monospacedDigit()); Text(sync.status).font(.caption2).foregroundColor(.secondary).lineLimit(1) }
                    Spacer()
                    Button { Task { await session.turn(forward: true) } } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一页")
                }.padding(.horizontal, 24).padding(.vertical, 10).background(Color(UIColor.secondarySystemBackground))
            }
            .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("完成") { closing = true; Task { await session.close(); dismiss() } }.disabled(closing) }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("目录").disabled(!session.ready)
                    if store.book(session.bookID)?.format == .epub { Button { showPreferences = true } label: { Image(systemName: "textformat.size") }.accessibilityLabel("阅读设置") }
                    Button { Task { await session.synchronize() } } label: { Image(systemName: "arrow.triangle.2.circlepath") }.accessibilityLabel("同步进度")
                }
            }
        }.navigationViewStyle(.stack)
        .task { await session.load() }
        .onChange(of: phase) { value in Task { if value == .active { await session.synchronize() } else if value == .background { await session.background() } } }
        .sheet(isPresented: $showContents) {
            ReaderContentsView(session: session)
        }
        .sheet(isPresented: $showPreferences) { ReaderPreferencesView(store: store, onChange: { session.updatePreferences() }) }
        .alert(item: $session.prompt) { prompt in
            let percentage = Int((prompt.remote.percentage ?? 0)*100)
            switch prompt.kind {
            case .conflict:
                return Alert(title: Text("选择阅读位置"), message: Text("本机 \(Int(session.progression*100))%，远端 \(percentage)%。两端都有变化。"), primaryButton: .default(Text("使用远端")) { session.prompt = nil; Task { await session.receive(prompt.remote) } }, secondaryButton: .default(Text("保留并上传本机")) { session.prompt = nil; Task { await session.synchronize(preferLocal: true) } })
            case .approximate:
                return Alert(title: Text("无法精确解析远端位置"), message: Text("是否按 \(percentage)% 近似跳转？不同阅读器可能落在不同段落。"), primaryButton: .default(Text("近似跳转")) { session.prompt = nil; Task { await session.receive(prompt.remote, approximate: true) } }, secondaryButton: .cancel(Text("保留本机")) { session.prompt = nil })
            }
        }
        .errorAlert($session.error)
    }
}
private struct ReaderContentsView: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var locating = true
    private let positionID = "current-reading-position"

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    if !locating && session.currentContentsID == nil { currentPosition }
                    ForEach(session.contents) { item in
                        Button {
                            dismiss()
                            Task { await session.go(item) }
                        } label: {
                            HStack(spacing: 16) {
                                Text(item.title).foregroundColor(.primary)
                                Spacer(minLength: 8)
                                if let page = item.pdfPage {
                                    Text("\(page + 1)").font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
                                }
                            }.padding(.vertical, 8)
                        }
                        if !locating && item.id == session.currentContentsID { currentPosition }
                    }
                }
                .listStyle(.plain)
                .overlay { if locating { ProgressView("正在定位…") } }
                .task {
                    await session.refreshContentsPosition()
                    guard !Task.isCancelled else { return }
                    locating = false
                }
                .onChange(of: locating) { value in
                    if !value { proxy.scrollTo(positionID, anchor: .center) }
                }
            }
            .navigationTitle("目录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }.navigationViewStyle(.stack)
    }

    private var currentPosition: some View {
        Button { dismiss() } label: {
            HStack(spacing: 16) {
                Label("当前位置", systemImage: "book")
                    .foregroundColor(.accentColor)
                Spacer(minLength: 8)
                Text(session.progressLabel)
                    .font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }.padding(.vertical, 8)
        }
        .id(positionID)
        .accessibilityLabel("当前位置，\(session.progressLabel)")
        .accessibilityHint("关闭目录，继续阅读")
    }
}
struct ReaderPreferencesView: View {
    @ObservedObject var store: LibraryStore
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("字号")) {
                    Slider(value: Binding(get: { store.settings.reader.fontSize }, set: { value in save { $0.fontSize = value } }), in: 80...200, step: 10)
                    Text("\(Int(store.settings.reader.fontSize))%")
                }
                Picker("主题", selection: Binding(get: { store.settings.reader.theme }, set: { value in save { $0.theme = value } })) {
                    Text("日间").tag("light"); Text("暖色").tag("sepia"); Text("夜间").tag("dark")
                }
            }.navigationTitle("阅读设置").toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }.navigationViewStyle(.stack).errorAlert($error)
    }
    private func save(_ change: (inout ReaderSettings) -> Void) {
        do { var settings = store.settings; change(&settings.reader); try store.saveSettings(settings); onChange() } catch { self.error = error.localizedDescription }
    }
}
