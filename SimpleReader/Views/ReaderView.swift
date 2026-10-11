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
    @State private var showSyncStatus = false
    @AppStorage("reader.showPageButtons") private var showPageButtons = false
    @AppStorage("reader.showProgress") private var showProgress = true
    @AppStorage("reader.didShowControlsHint") private var didShowControlsHint = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(bookID: UUID, environment: AppEnvironment) {
        self.init(session: ReaderSession(bookID: bookID, store: environment.store, readium: environment.readium, sync: environment.sync), store: environment.store, sync: environment.sync)
    }
    init(session: ReaderSession, store: LibraryStore, sync: SyncCoordinator) {
        self.store = store; self.sync = sync
        _session = StateObject(wrappedValue: session)
    }
    var body: some View {
        ReaderSurface(session: session)
        .overlay {
            if let error = session.recoveryError {
                VStack(spacing: 12) {
                    Text(error)
                    Button("重新加载正文") { Task { await session.retryRecovery() } }
                }.padding().background(Color(UIColor.systemBackground))
            } else if session.isRestoring {
                ProgressView("正在恢复阅读位置…")
            } else if !session.ready && session.error == nil {
                ProgressView("正在打开…")
            }
        }
        .accessibilityAction(named: Text("显示或隐藏阅读操作栏")) { session.toggleControls() }
        .overlay(alignment: .top) { if session.controlsVisible { topControls.transition(.opacity) } }
        .overlay(alignment: .bottom) {
            VStack(spacing: 4) {
                if let message = session.syncMessage, message.hasPrefix("同步失败") {
                    Button { showSyncStatus = true } label: {
                        Label("同步失败，点击查看", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption).padding(12).background(.regularMaterial, in: Capsule())
                    }
                }
                if session.controlsVisible { bottomControls.transition(.opacity) }
                else if showProgress {
                    Button { session.toggleControls() } label: {
                        Text(session.progressLabel).font(.caption.monospacedDigit())
                            .padding(.horizontal, 12).frame(minHeight: 44).background(.regularMaterial, in: Capsule())
                    }.accessibilityLabel("\(session.progressLabel)，显示阅读操作栏")
                }
            }
        }
        .preferredColorScheme(store.settings.reader.theme == "dark" ? .dark : store.settings.reader.theme == "light" ? .light : nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: session.controlsVisible)
        .task { await session.load() }
        .onChange(of: phase) { value in
            switch value {
            case .inactive: session.resignActive()
            case .background: Task { await session.background() }
            case .active: Task { await session.foreground() }
            @unknown default: break
            }
        }
        .sheet(isPresented: $showContents) {
            ReaderContentsView(session: session)
        }
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
        .alert("同步失败", isPresented: $showSyncStatus) {
            Button("重试") { Task { await session.synchronize(userInitiated: true) } }
            Button("关闭", role: .cancel) {}
        } message: { Text(session.syncMessage ?? sync.status) }
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            Button {
                closing = true
                Task { await session.close(); dismiss() }
            } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                .accessibilityLabel("返回书库").disabled(closing)
            Text(session.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            Menu {
                Text(session.syncMessage ?? sync.status)
                Button {
                    Task { await session.synchronize(userInitiated: true) }
                } label: { Label("同步进度", systemImage: "arrow.triangle.2.circlepath") }
                Toggle("显示细小进度", isOn: $showProgress)
                if !session.isScrolling { Toggle("显示翻页按钮", isOn: $showPageButtons) }
                if let warning = session.bridgeWarning { Text(warning) }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("更多阅读选项")
        }.padding(.horizontal, 8).background(.regularMaterial)
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            if !didShowControlsHint && session.ready {
                HStack {
                    Text("点击正文中央收起或显示操作栏").font(.caption)
                    Button("知道了") { didShowControlsHint = true }.font(.caption)
                }
            }
            Text(session.progressLabel).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            HStack {
                Button { showContents = true } label: { Label("目录", systemImage: "list.bullet").frame(minHeight: 44) }
                    .disabled(!session.ready)
                Spacer()
                if showPageButtons && !session.isScrolling {
                    Button { Task { await session.turn(forward: false) } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上一页")
                    Button { Task { await session.turn(forward: true) } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下一页")
                    Spacer()
                }
                if store.book(session.bookID)?.format == .epub {
                    Button { showPreferences = true } label: { Label("设置", systemImage: "textformat.size").frame(minHeight: 44) }
                        .accessibilityLabel("阅读设置").disabled(!session.ready)
                        .popover(isPresented: $showPreferences) { preferencesPanel }
                }
                Button { session.toggleControls() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("收起阅读操作栏")
            }
        }.padding(.horizontal, 16).padding(.top, 10).background(.regularMaterial)
    }

    @ViewBuilder private var preferencesPanel: some View {
        if #available(iOS 16.0, *) {
            ReaderPreferencesView(store: store, supportsScrolling: session.supportsScrolling, onChange: { session.updatePreferences() })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        } else {
            ReaderPreferencesView(store: store, supportsScrolling: session.supportsScrolling, onChange: { session.updatePreferences() })
        }
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
    var supportsScrolling = true
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationView {
            Form {
                if supportsScrolling {
                    Section(header: Text("阅读方式")) {
                        Picker("阅读方式", selection: Binding(get: { store.settings.reader.layout }, set: { value in save { $0.layout = value } })) {
                            Text("分页").tag(ReadingLayout.paginated)
                            Text("连续滚动").tag(ReadingLayout.scroll)
                        }.pickerStyle(.segmented)
                    }
                    Section(header: Text("字体与排版")) {
                        Picker("字体", selection: Binding(get: { store.settings.reader.font }, set: { value in save { $0.font = value } })) {
                            Text("书籍衬线").tag(ReaderFont.serif)
                            Text("系统无衬线").tag(ReaderFont.system)
                        }
                        VStack(alignment: .leading) {
                            Text("字号 \(Int(store.settings.reader.fontSize))%")
                            Slider(value: Binding(get: { store.settings.reader.fontSize }, set: { value in save { $0.fontSize = value } }), in: 80...200, step: 10)
                                .accessibilityLabel("字号")
                        }
                        VStack(alignment: .leading) {
                            Text("行距 \(store.settings.reader.lineHeight, specifier: "%.2f") 倍")
                            Slider(value: Binding(get: { store.settings.reader.lineHeight }, set: { value in save { $0.lineHeight = value } }), in: 1.2...2.0, step: 0.05)
                                .accessibilityLabel("行距")
                        }
                        VStack(alignment: .leading) {
                            Text("页边距 \(store.settings.reader.pageMargins, specifier: "%.2f") 倍")
                            Slider(value: Binding(get: { store.settings.reader.pageMargins }, set: { value in save { $0.pageMargins = value } }), in: 0.5...2.0, step: 0.25)
                                .accessibilityLabel("页边距")
                        }
                    }
                }
                Picker("主题", selection: Binding(get: { store.settings.reader.theme }, set: { value in save { $0.theme = value } })) {
                    Text("跟随系统").tag("system"); Text("日间").tag("light"); Text("夜间").tag("dark")
                }
            }.navigationTitle("阅读设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }.navigationViewStyle(.stack).errorAlert($error)
    }
    private func save(_ change: (inout ReaderSettings) -> Void) {
        do { var settings = store.settings; change(&settings.reader); try store.saveSettings(settings); onChange() } catch { self.error = error.localizedDescription }
    }
}
