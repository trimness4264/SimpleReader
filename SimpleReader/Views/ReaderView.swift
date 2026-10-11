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
    @State private var showPageJump = false
    @State private var closing = false
    @State private var showSyncStatus = false
    @AppStorage("reader.showPageButtons") private var showPageButtons = false
    @AppStorage("reader.showProgress") private var showProgress = true
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
        .ignoresSafeArea(.keyboard)
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
        .sheet(isPresented: $showPageJump) { PDFPageJumpView(session: session) }
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
            if session.canReturnToPreviousPosition {
                Button { Task { await session.returnToPreviousPosition() } } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }.accessibilityLabel("返回刚才位置").disabled(session.isNavigating || session.isRestoring)
            }
            Menu {
                Text(session.syncMessage ?? sync.status)
                Button {
                    Task { await session.synchronize(userInitiated: true) }
                } label: { Label("同步进度", systemImage: "arrow.triangle.2.circlepath") }
                Toggle("显示细小进度", isOn: $showProgress)
                if !session.isScrolling { Toggle("显示翻页按钮", isOn: $showPageButtons) }
                if let warning = session.bridgeWarning { Text(warning) }
                Button("收起阅读操作栏") { session.toggleControls() }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("更多阅读选项")
        }.padding(.horizontal, 8).background(.regularMaterial)
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            ReaderProgressSlider(session: session)
            HStack(spacing: 12) {
                Button { showContents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                    .accessibilityLabel("目录")
                    .disabled(!session.ready || session.isNavigating)
                Spacer()
                if showPageButtons && !session.isScrolling {
                    Button { Task { await session.turn(forward: false) } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上一页")
                }
                if session.pdfPageCount != nil {
                    Button { showPageJump = true } label: {
                        HStack(spacing: 6) {
                            Text(session.progressLabel).font(.subheadline.monospacedDigit())
                            Image(systemName: "chevron.down").font(.caption2)
                        }.frame(minHeight: 44)
                    }.accessibilityLabel("\(session.progressLabel)，跳转页码")
                } else {
                    Text(session.progressLabel).font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
                }
                if showPageButtons && !session.isScrolling {
                    Button { Task { await session.turn(forward: true) } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下一页")
                }
                Spacer()
                if store.book(session.bookID)?.format == .epub {
                    Button { showPreferences = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                        .accessibilityLabel("阅读设置").disabled(!session.ready || session.isNavigating)
                        .popover(isPresented: $showPreferences) { preferencesPanel }
                } else {
                    Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                }
            }
            .disabled(!session.ready || session.isNavigating || session.isRestoring)
        }.padding(.horizontal, 16).padding(.top, 8).background(.regularMaterial)
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
private struct ReaderProgressSlider: View {
    @ObservedObject var session: ReaderSession
    @State private var draftProgression: Double?

    private var sliderProgression: Double {
        if let count = session.pdfPageCount, let page = session.currentPDFPage {
            return count > 1 ? Double(page - 1) / Double(count - 1) : 0
        }
        return min(max(session.progression, 0), 1)
    }
    private var displayedProgression: Double { draftProgression ?? sliderProgression }
    private var previewLabel: String {
        guard draftProgression != nil else { return session.progressLabel }
        if let count = session.pdfPageCount {
            let page = Int((displayedProgression * Double(max(0, count - 1))).rounded()) + 1
            return "第 \(page) / \(count) 页"
        }
        return "\(Int((displayedProgression * 100).rounded()))%"
    }

    var body: some View {
            Slider(value: Binding(get: { displayedProgression }, set: { draftProgression = $0 }), in: 0...1) { editing in
                if editing {
                    draftProgression = sliderProgression
                } else if let target = draftProgression {
                    Task {
                        await session.jump(toProgression: target)
                        draftProgression = nil
                    }
                }
            }
            .frame(height: 44)
            .overlay(alignment: .top) {
                if draftProgression != nil {
                    Text(previewLabel).font(.caption.monospacedDigit())
                        .padding(8).background(.regularMaterial, in: Capsule())
                        .offset(y: -24).allowsHitTesting(false)
                }
            }
            .accessibilityLabel("阅读进度")
            .accessibilityValue(previewLabel)
            .accessibilityHint("调整后跳转到所选位置")
        .disabled(!session.ready || session.isRestoring || session.isNavigating)
    }
}

struct PDFPageJumpView: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var pageInput = ""
    @State private var pageInputError: String?
    @FocusState private var pageInputFocused: Bool

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("页码")
                        TextField(session.currentPDFPage.map(String.init) ?? "输入页码", text: $pageInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($pageInputFocused)
                            .accessibilityLabel("跳转页码")
                            .accessibilityIdentifier("pdf.pageInput")
                            .onSubmit { jump() }
                            .onChange(of: pageInput) { _ in pageInputError = nil }
                            .disabled(session.isNavigating)
                    }
                } footer: {
                    if let pageInputError { Text(pageInputError).foregroundColor(.red) }
                    else { Text("共 \(session.pdfPageCount ?? 0) 页") }
                }
            }
            .navigationTitle("跳转页码").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("跳转") { jump() }
                        .disabled(pageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isNavigating || session.isRestoring)
                }
            }
            .task { pageInputFocused = true }
        }.navigationViewStyle(.stack)
    }

    private func jump() {
        guard let count = session.pdfPageCount,
              let page = Int(pageInput.trimmingCharacters(in: .whitespacesAndNewlines)), (1...count).contains(page) else {
            pageInputError = "请输入 1 到 \(session.pdfPageCount ?? 0) 的页码"
            return
        }
        pageInputFocused = false
        Task {
            await session.jump(toPage: page)
            if session.currentPDFPage == page { dismiss() }
        }
    }
}
private struct ReaderContentsView: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var locating = true
    @State private var searchText = ""
    private let positionID = "current-reading-position"

    private var filteredContents: [ContentsItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? session.contents : session.contents.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                List {
                    if !locating && !filteredContents.contains(where: { $0.id == session.currentContentsID }) { currentPosition }
                    ForEach(filteredContents) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                dismiss()
                                Task { await session.go(item) }
                            } label: {
                                HStack(spacing: 16) {
                                    Text(item.title)
                                        .fontWeight(item.id == session.currentContentsID ? .semibold : .regular)
                                        .foregroundColor(item.id == session.currentContentsID ? .accentColor : .primary)
                                    Spacer(minLength: 8)
                                    if item.id == session.currentContentsID {
                                        Image(systemName: "checkmark").foregroundColor(.accentColor)
                                            .accessibilityLabel("当前章节")
                                    }
                                    if let page = item.pdfPage {
                                        Text("\(page + 1)").font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
                                    }
                                }.padding(.vertical, 8).frame(minHeight: 44)
                            }
                            .disabled(session.isNavigating)
                            if !locating && item.id == session.currentContentsID { currentPosition }
                        }
                    }
                    if filteredContents.isEmpty && !searchText.isEmpty {
                        Text("没有匹配的章节").foregroundColor(.secondary)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $searchText, prompt: "搜索章节")
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
