import SwiftUI

private struct ReaderSurface: UIViewControllerRepresentable {
    let session: ReaderSession
    let scrollInsets: UIEdgeInsets?

    func makeUIViewController(context: Context) -> UIViewController { session.container }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        session.updateScrollInsets(scrollInsets)
    }
}

private enum ReaderBar {
    case top, bottom, syncStatus
}

private struct ReaderBarHeights: PreferenceKey {
    static let defaultValue: [ReaderBar: CGFloat] = [:]

    static func reduce(value: inout [ReaderBar: CGFloat], nextValue: () -> [ReaderBar: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

struct ReaderView: View {
    @StateObject private var session: ReaderSession
    @ObservedObject private var store: LibraryStore
    @ObservedObject private var sync: SyncCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var barHeights: [ReaderBar: CGFloat] = [:]
    @State private var showRestorationProgress = false
    @State private var showContents = false
    @State private var showPreferences = false
    @State private var showProgressJump = false
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

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var isEPUB: Bool { store.book(session.bookID)?.format == .epub }
    private var isPagedEPUB: Bool { isEPUB && !session.isScrolling }
    private var readerColorScheme: ColorScheme? {
        store.settings.reader.theme.isDark.map { $0 ? .dark : .light }
    }
    private var controlsAnimation: Animation {
        .easeInOut(duration: reduceMotion ? 0.15 : 0.25)
    }

    private func controlsTransition(verticalOffset: CGFloat) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: verticalOffset))
    }

    var body: some View {
        GeometryReader { geometry in
            let topBar = session.controlsVisible ? barHeights[.top, default: 0] : 0
            let bottomBar = session.controlsVisible ? barHeights[.bottom, default: 0]
                : session.syncError != nil ? barHeights[.syncStatus, default: 0] : 0
            let scrollInsets = isPhone && !isPagedEPUB ? UIEdgeInsets(
                top: geometry.safeAreaInsets.top + topBar, left: 0,
                bottom: geometry.safeAreaInsets.bottom + bottomBar, right: 0
            ) : nil
            ReaderSurface(session: session, scrollInsets: scrollInsets)
                // Readium already reserves the window's safe area inside its pages.
                .padding(.top, isPhone && isPagedEPUB ? topBar : 0)
                .padding(.bottom, isPhone && isPagedEPUB ? bottomBar : 0)
                .ignoresSafeArea(.container, edges: isPhone ? .vertical : [])
        }
        .ignoresSafeArea(.keyboard)
        .overlay {
            if let error = session.recoveryError {
                VStack(spacing: 12) {
                    Text(error)
                    Button("Reload Book") { Task { await session.retryRecovery() } }
                }.padding().background(Color(UIColor.systemBackground))
            } else if !session.ready && session.error == nil {
                ProgressView("Opening…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
            } else if session.isRestoring && showRestorationProgress {
                ProgressView("Restoring reading position…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityAction(named: Text("Show or hide reading controls")) { session.toggleControls() }
        .overlay(alignment: .top) { topOverlay }
        .overlay(alignment: .bottom) { bottomOverlay }
        .onPreferenceChange(ReaderBarHeights.self) { heights in
            // Keep the last measurement while controls are hidden so they can reserve space immediately.
            barHeights.merge(heights) { _, height in height }
        }
        .preferredColorScheme(readerColorScheme)
        .statusBarHidden(isPhone)
        .task(id: session.isRestoring) {
            showRestorationProgress = false
            guard session.isRestoring else { return }
            // A short pagination pass should not flash a loading screen over the page.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            showRestorationProgress = true
        }
        .task { await session.load() }
        .onChange(of: phase) { _, value in
            switch value {
            case .inactive: session.resignActive()
            case .background: Task { await session.background() }
            case .active: Task { await session.foreground() }
            @unknown default: break
            }
        }
        .sheet(isPresented: $showContents) {
            NavigationStack { ReaderContentsView(session: session, mode: .browse) }
        }
        .sheet(isPresented: $showProgressJump) {
            Group {
                if session.pdfPageCount != nil {
                    PDFPageJumpView(session: session)
                } else {
                    EPUBProgressJumpView(session: session)
                }
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPreferences) { preferencesPanel }
        .alert(item: $session.prompt) { prompt in
            let percentage = Int((prompt.remote.percentage ?? 0)*100)
            switch prompt.kind {
            case .conflict:
                return Alert(title: Text("Choose a Reading Position"), message: Text("On this device: \(Int(session.progression*100))%. On the server: \(percentage)%. Both positions have changed."), primaryButton: .default(Text("Use Server Position")) { session.prompt = nil; Task { await session.receive(prompt.remote, revision: prompt.revision) } }, secondaryButton: .default(Text("Keep and Upload Local Position")) { session.prompt = nil; Task { await session.synchronize(preferLocal: true) } })
            case .approximate:
                return Alert(title: Text("Couldn’t Locate the Exact Server Position"), message: Text("Jump to approximately \(percentage)%? Different readers may land on different paragraphs."), primaryButton: .default(Text("Jump to Approximate Position")) { session.prompt = nil; Task { await session.receive(prompt.remote, approximate: true, revision: prompt.revision) } }, secondaryButton: .cancel(Text("Keep Local Position")) { session.prompt = nil })
            }
        }
        .errorAlert($session.error)
        .alert("Sync Failed", isPresented: $showSyncStatus) {
            Button("Retry") { Task { await session.synchronize(userInitiated: true) } }
            Button("Close", role: .cancel) {}
        } message: { Text(session.syncMessage ?? sync.status) }
    }

    private var topOverlay: some View {
        ZStack {
            if session.controlsVisible {
                topControls
                    .background { barHeight(.top) }
                    .transition(controlsTransition(verticalOffset: -8))
            }
        }
        .animation(controlsAnimation, value: session.controlsVisible)
    }

    private var bottomOverlay: some View {
        VStack(spacing: 4) {
            if session.syncError != nil {
                Button { showSyncStatus = true } label: {
                    Label("Sync failed. Tap for details.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption).padding(12).background(.regularMaterial, in: Capsule())
                }
            }
            Group {
                if session.controlsVisible {
                    bottomControls.transition(controlsTransition(verticalOffset: 8))
                } else if showProgress {
                    progressJumpButton(compact: true).transition(.opacity)
                }
            }
            .disabled(!session.ready || session.isNavigating || session.isRestoring)
        }
        .background {
            if session.controlsVisible {
                barHeight(.bottom)
            } else if session.syncError != nil {
                barHeight(.syncStatus)
            }
        }
        .animation(controlsAnimation, value: session.controlsVisible)
    }

    private func barHeight(_ bar: ReaderBar) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ReaderBarHeights.self, value: [bar: geometry.size.height])
        }
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            Button {
                closing = true
                Task { await session.close(); dismiss() }
            } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                .accessibilityLabel("Back to library").disabled(closing)
            Text(session.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            if session.canReturnToPreviousPosition {
                Button { Task { await session.returnToPreviousPosition() } } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }.accessibilityLabel("Return to previous position").disabled(session.isNavigating || session.isRestoring)
            }
            Menu {
                Text(session.syncMessage ?? sync.status)
                Button {
                    Task { await session.synchronize(userInitiated: true) }
                } label: { Label("Sync Reading Progress", systemImage: "arrow.triangle.2.circlepath") }
                Toggle("Show Compact Progress Indicator", isOn: $showProgress)
                if !session.isScrolling { Toggle("Show Page Turn Buttons", isOn: $showPageButtons) }
                if let warning = session.bridgeWarning { Text(warning) }
                Button("Hide Reading Controls") { session.toggleControls() }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("More reading options")
        }.padding(.horizontal, 8).background(.regularMaterial)
    }

    private var bottomControls: some View {
        HStack(spacing: 12) {
            Button { showContents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("Contents")
            Spacer(minLength: 0)
            if showPageButtons && !session.isScrolling {
                Button { Task { await session.turn(forward: false) } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous page")
            }
            progressJumpButton(compact: false).layoutPriority(1)
            if showPageButtons && !session.isScrolling {
                Button { Task { await session.turn(forward: true) } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Next page")
            }
            Spacer(minLength: 0)
            if isEPUB {
                Button { showPreferences = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                    .accessibilityLabel("Reading Settings")
            } else {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).background(.regularMaterial)
    }

    private func progressJumpButton(compact: Bool) -> some View {
        Button { showProgressJump = true } label: {
            HStack(spacing: 6) {
                Text(session.progressLabel)
                    .font((compact ? Font.caption : .subheadline).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up").font(.caption2)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, compact ? 12 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .background {
                if compact {
                    Capsule().fill(.regularMaterial)
                }
            }
        }
        .accessibilityLabel("Reading progress")
        .accessibilityValue(session.progressLabel)
        .accessibilityHint("Opens the position jump panel")
    }

    private var preferencesPanel: some View {
        NavigationStack {
            ReaderPreferencesView(store: store, supportsScrolling: session.supportsScrolling, onChange: { session.updatePreferences() })
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
private struct EPUBProgressJumpView: View {
    private enum Target {
        case progression(Double)
        case chapter(ContentsItem)
    }

    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var target: Target?

    private let percentageFormat = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0...2))

    private var progression: Double {
        if case .progression(let value) = target { return value }
        return min(max(session.progression, 0), 1)
    }

    private var destinationLabel: String {
        switch target {
        case .progression(let value): value.formatted(percentageFormat)
        case .chapter(let item): item.title
        case nil: String(localized: "Not selected")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current Position", value: session.progressLabel)
                    LabeledContent("Destination", value: destinationLabel)
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Percentage").accessibilityHidden(true)
                        Slider(value: Binding(get: { progression }, set: { target = .progression($0) }), in: 0...1)
                            .accessibilityLabel("Percentage")
                            .accessibilityValue(progression.formatted(percentageFormat))
                    }
                    if !session.contents.isEmpty {
                        NavigationLink("Choose Chapter") {
                            ReaderContentsView(session: session, mode: .chooseChapter { target = .chapter($0) })
                        }
                    }
                }
            }
            .navigationTitle("Go to Position").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { jump() }
                        .disabled(target == nil || session.isNavigating || session.isRestoring)
                }
            }
        }
    }

    private func jump() {
        guard let target, !session.isNavigating, !session.isRestoring else { return }
        dismiss()
        Task {
            switch target {
            case .progression(let value): await session.jump(toProgression: value)
            case .chapter(let item): await session.go(item)
            }
        }
    }
}

struct PDFPageJumpView: View {
    @ObservedObject var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @State private var pageInput = ""
    @State private var pageInputError: String?
    @State private var submitting = false
    @FocusState private var pageInputFocused: Bool

    private var enteredPage: String { pageInput.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isBusy: Bool { submitting || session.isNavigating || session.isRestoring }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Page")
                        TextField(session.currentPDFPage.map(String.init) ?? String(localized: "Enter page number"), text: $pageInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($pageInputFocused)
                            .accessibilityLabel("Go to Page")
                            .accessibilityIdentifier("pdf.pageInput")
                            .onChange(of: pageInput) { pageInputError = nil }
                            .disabled(isBusy)
                    }
                } footer: {
                    if let pageInputError { Text(pageInputError).foregroundColor(.red) }
                    else { Text("Total pages: \(session.pdfPageCount ?? 0)") }
                }
            }
            .navigationTitle("Go to Page").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { jump() }
                        .disabled(enteredPage.isEmpty || isBusy)
                }
            }
            .task { pageInputFocused = true }
        }
        .interactiveDismissDisabled(submitting)
    }

    private func jump() {
        guard !isBusy else { return }
        guard let count = session.pdfPageCount,
              let page = Int(enteredPage), (1...count).contains(page) else {
            pageInputError = String(localized: "Enter a page number from 1 to \(session.pdfPageCount ?? 0).")
            return
        }
        pageInputError = nil
        pageInputFocused = false
        submitting = true
        Task {
            defer { submitting = false }
            let reachedPage = await session.jump(toPage: page) { pageInputError = $0.localizedDescription }
            if reachedPage {
                dismiss()
            } else if pageInputError == nil {
                pageInputError = String(localized: "Couldn’t jump to the selected position.")
            }
        }
    }
}
private struct ReaderContentsView: View {
    enum Mode {
        case browse
        case chooseChapter((ContentsItem) -> Void)
    }

    @ObservedObject var session: ReaderSession
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var locating = true
    @State private var searchText = ""
    private let positionID = "current-reading-position"

    private var filteredContents: [ContentsItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? session.contents : session.contents.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        switch mode {
        case .browse:
            contents(showCurrentPosition: true) { item in
                Task { await session.go(item) }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        case .chooseChapter(let onSelect):
            contents(showCurrentPosition: false, onSelect: onSelect)
                .navigationTitle("Choose Chapter")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func contents(showCurrentPosition: Bool, onSelect: @escaping (ContentsItem) -> Void) -> some View {
        ScrollViewReader { proxy in
            List {
                if showCurrentPosition && !locating && !filteredContents.contains(where: { $0.id == session.currentContentsID }) { currentPosition }
                ForEach(filteredContents) { item in
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            dismiss()
                            onSelect(item)
                        } label: {
                            HStack(spacing: 16) {
                                Text(item.title)
                                    .fontWeight(item.id == session.currentContentsID ? .semibold : .regular)
                                    .foregroundColor(item.id == session.currentContentsID ? .accentColor : .primary)
                                Spacer(minLength: 8)
                                if item.id == session.currentContentsID {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                        .accessibilityLabel("Current chapter")
                                }
                                if let page = item.pdfPage {
                                    Text("\(page + 1)").font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
                                }
                            }.padding(.vertical, 8).frame(minHeight: 44)
                        }
                        .disabled(session.isNavigating)
                        if showCurrentPosition && !locating && item.id == session.currentContentsID { currentPosition }
                    }
                }
                if filteredContents.isEmpty && !searchText.isEmpty {
                    Text("No matching chapters").foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Search chapters")
            .overlay { if locating { ProgressView("Finding position…") } }
            .task {
                await session.refreshContentsPosition()
                guard !Task.isCancelled else { return }
                locating = false
            }
            .onChange(of: locating) { _, value in
                guard !value else { return }
                if showCurrentPosition {
                    proxy.scrollTo(positionID, anchor: .center)
                } else if let current = session.currentContentsID {
                    proxy.scrollTo(current, anchor: .center)
                }
            }
        }
    }

    private var currentPosition: some View {
        Button { dismiss() } label: {
            HStack(spacing: 16) {
                Label("Current Position", systemImage: "book")
                    .foregroundColor(.accentColor)
                Spacer(minLength: 8)
                Text(session.progressLabel)
                    .font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
            }.padding(.vertical, 8)
        }
        .id(positionID)
        .accessibilityLabel("Current position, \(session.progressLabel)")
        .accessibilityHint("Close contents and continue reading")
    }
}
struct ReaderPreferencesView: View {
    @ObservedObject var store: LibraryStore
    var supportsScrolling = true
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        Form {
            if supportsScrolling {
                Section(header: Text("Reading Mode")) {
                    Picker("Reading Mode", selection: Binding(get: { store.settings.reader.layout }, set: { value in save { $0.layout = value } })) {
                        Text("Paginated").tag(ReadingLayout.paginated)
                        Text("Continuous Scrolling").tag(ReadingLayout.scroll)
                    }.pickerStyle(.segmented)
                }
                Section(header: Text("Typography")) {
                    Picker("Font", selection: Binding(get: { store.settings.reader.font }, set: { value in save { $0.font = value } })) {
                        Text("Book Serif").tag(ReaderFont.serif)
                        Text("System Sans Serif").tag(ReaderFont.system)
                    }
                    VStack(alignment: .leading) {
                        Text("Font size: \(Int(store.settings.reader.fontSize))%")
                        Slider(value: Binding(get: { store.settings.reader.fontSize }, set: { value in save { $0.fontSize = value } }), in: 80...200, step: 10)
                            .accessibilityLabel("Font size")
                    }
                    VStack(alignment: .leading) {
                        Text("Line spacing: \(store.settings.reader.lineHeight, specifier: "%.2f")×")
                        Slider(value: Binding(get: { store.settings.reader.lineHeight }, set: { value in save { $0.lineHeight = value } }), in: 1.2...2.0, step: 0.05)
                            .accessibilityLabel("Line spacing")
                    }
                    VStack(alignment: .leading) {
                        Text("Page margins: \(store.settings.reader.pageMargins, specifier: "%.2f")×")
                        Slider(value: Binding(get: { store.settings.reader.pageMargins }, set: { value in save { $0.pageMargins = value } }), in: 0.5...2.0, step: 0.25)
                            .accessibilityLabel("Page margins")
                    }
                }
            }
            Picker("Theme", selection: Binding(get: { store.settings.reader.theme }, set: { value in save { $0.theme = value } })) {
                Text("System").tag(ReaderTheme.system)
                Text("Light").tag(ReaderTheme.light)
                Text("Dark").tag(ReaderTheme.dark)
            }
        }
        .navigationTitle("Reading Settings").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        .errorAlert($error)
    }
    private func save(_ change: (inout ReaderSettings) -> Void) {
        do { var settings = store.settings; change(&settings.reader); try store.saveSettings(settings); onChange() } catch { self.error = error.localizedDescription }
    }
}
