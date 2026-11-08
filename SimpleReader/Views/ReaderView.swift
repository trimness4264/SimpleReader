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
                    Button("Reload Book") { Task { await session.retryRecovery() } }
                }.padding().background(Color(UIColor.systemBackground))
            } else if session.isRestoring || (!session.ready && session.error == nil) {
                ProgressView {
                    Text(session.isRestoring ? LocalizedStringKey("Restoring reading position…") : LocalizedStringKey("Opening…"))
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground))
            }
        }
        .accessibilityAction(named: Text("Show or hide reading controls")) { session.toggleControls() }
        .overlay(alignment: .top) { if session.controlsVisible { topControls.transition(.opacity) } }
        .overlay(alignment: .bottom) {
            VStack(spacing: 4) {
                if session.syncError != nil {
                    Button { showSyncStatus = true } label: {
                        Label("Sync failed. Tap for details.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption).padding(12).background(.regularMaterial, in: Capsule())
                    }
                }
                if session.controlsVisible { bottomControls.transition(.opacity) }
                else if showProgress {
                    Button { session.toggleControls() } label: {
                        Text(session.progressLabel).font(.caption.monospacedDigit())
                            .padding(.horizontal, 12).frame(minHeight: 44).background(.regularMaterial, in: Capsule())
                    }.accessibilityLabel("\(session.progressLabel), show reading controls")
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
        .sheet(isPresented: $showPreferences) { preferencesPanel }
        .alert(item: $session.prompt) { prompt in
            let percentage = Int((prompt.remote.percentage ?? 0)*100)
            switch prompt.kind {
            case .conflict:
                return Alert(title: Text("Choose a Reading Position"), message: Text("On this device: \(Int(session.progression*100))%. On the server: \(percentage)%. Both positions have changed."), primaryButton: .default(Text("Use Server Position")) { session.prompt = nil; Task { await session.receive(prompt.remote) } }, secondaryButton: .default(Text("Keep and Upload Local Position")) { session.prompt = nil; Task { await session.synchronize(preferLocal: true) } })
            case .approximate:
                return Alert(title: Text("Couldn’t Locate the Exact Server Position"), message: Text("Jump to approximately \(percentage)%? Different readers may land on different paragraphs."), primaryButton: .default(Text("Jump to Approximate Position")) { session.prompt = nil; Task { await session.receive(prompt.remote, approximate: true) } }, secondaryButton: .cancel(Text("Keep Local Position")) { session.prompt = nil })
            }
        }
        .errorAlert($session.error)
        .alert("Sync Failed", isPresented: $showSyncStatus) {
            Button("Retry") { Task { await session.synchronize(userInitiated: true) } }
            Button("Close", role: .cancel) {}
        } message: { Text(session.syncMessage ?? sync.status) }
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
        VStack(spacing: 0) {
            ReaderProgressSlider(session: session)
            HStack(spacing: 12) {
                Button { showContents = true } label: { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                    .accessibilityLabel("Contents")
                    .disabled(!session.ready || session.isNavigating)
                Spacer()
                if showPageButtons && !session.isScrolling {
                    Button { Task { await session.turn(forward: false) } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous page")
                }
                if session.pdfPageCount != nil {
                    Button { showPageJump = true } label: {
                        HStack(spacing: 6) {
                            Text(session.progressLabel).font(.subheadline.monospacedDigit())
                            Image(systemName: "chevron.down").font(.caption2)
                        }.frame(minHeight: 44)
                    }.accessibilityLabel("\(session.progressLabel), go to page")
                } else {
                    Text(session.progressLabel).font(.subheadline.monospacedDigit()).foregroundColor(.secondary)
                }
                if showPageButtons && !session.isScrolling {
                    Button { Task { await session.turn(forward: true) } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Next page")
                }
                Spacer()
                if store.book(session.bookID)?.format == .epub {
                    Button { showPreferences = true } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                        .accessibilityLabel("Reading Settings").disabled(!session.ready || session.isNavigating)
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
            return String(localized: "Page \(page) of \(count)")
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
            .accessibilityLabel("Reading progress")
            .accessibilityValue(previewLabel)
            .accessibilityHint("Adjust to jump to the selected position")
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
                        Text("Page")
                        TextField(session.currentPDFPage.map(String.init) ?? String(localized: "Enter page number"), text: $pageInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .focused($pageInputFocused)
                            .accessibilityLabel("Go to Page")
                            .accessibilityIdentifier("pdf.pageInput")
                            .onSubmit { jump() }
                            .onChange(of: pageInput) { _ in pageInputError = nil }
                            .disabled(session.isNavigating)
                    }
                } footer: {
                    if let pageInputError { Text(pageInputError).foregroundColor(.red) }
                    else { Text("Total pages: \(session.pdfPageCount ?? 0)") }
                }
            }
            .navigationTitle("Go to Page").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") { jump() }
                        .disabled(pageInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.isNavigating || session.isRestoring)
                }
            }
            .task { pageInputFocused = true }
        }.navigationViewStyle(.stack)
    }

    private func jump() {
        guard let count = session.pdfPageCount,
              let page = Int(pageInput.trimmingCharacters(in: .whitespacesAndNewlines)), (1...count).contains(page) else {
            pageInputError = String(localized: "Enter a page number from 1 to \(session.pdfPageCount ?? 0).")
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
                                            .accessibilityLabel("Current chapter")
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
                .onChange(of: locating) { value in
                    if !value { proxy.scrollTo(positionID, anchor: .center) }
                }
            }
            .navigationTitle("Contents").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }.navigationViewStyle(.stack)
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
        NavigationView {
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
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }.navigationTitle("Reading Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }.navigationViewStyle(.stack).errorAlert($error)
    }
    private func save(_ change: (inout ReaderSettings) -> Void) {
        do { var settings = store.settings; change(&settings.reader); try store.saveSettings(settings); onChange() } catch { self.error = error.localizedDescription }
    }
}
