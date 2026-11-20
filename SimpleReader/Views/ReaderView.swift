import SwiftUI

private struct ReaderSurface: UIViewControllerRepresentable {
    let session: ReaderSession
    let scrollInsets: UIEdgeInsets?

    func makeUIViewController(context: Context) -> UIViewController { session.container }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        session.updateScrollInsets(scrollInsets)
    }
}

struct ReaderView: View {
    @State private var session: ReaderSession
    @Environment(\.scenePhase) private var phase
    @State private var barHeights: [ReaderBar: CGFloat] = [:]
    @State private var showContents = false
    @State private var showPreferences = false
    @State private var showProgressJump = false
    init(bookID: UUID, environment: AppEnvironment) {
        _session = State(initialValue: ReaderSession(bookID: bookID, store: environment.store,
            readium: environment.readium, sync: environment.sync))
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var isPagedEPUB: Bool { session.bookFormat == .epub && !session.isScrolling }
    private var readerColorScheme: ColorScheme? {
        session.readerSettings.theme.isDark.map { $0 ? .dark : .light }
    }
    var body: some View {
        @Bindable var session = session
        // Keep the pagination viewport and PDF scroll offset stable while the controls animate.
        let reservesToolbarSpace = !session.isScrolling || session.controlsVisible
        GeometryReader { geometry in
            let topBar = reservesToolbarSpace ? barHeights[.top, default: 0] : 0
            let bottomBar = reservesToolbarSpace ? barHeights[.bottom, default: 0]
                : session.syncError != nil ? barHeights[.syncStatus, default: 0] : 0
            let padsViewport = isPhone && isPagedEPUB
            let scrollInsets = isPhone && !isPagedEPUB ? UIEdgeInsets(
                top: geometry.safeAreaInsets.top + topBar, left: 0,
                bottom: geometry.safeAreaInsets.bottom + bottomBar, right: 0
            ) : nil
            ReaderSurface(session: session, scrollInsets: scrollInsets)
                // Readium already reserves the window's safe area inside its pages.
                .padding(.top, padsViewport ? topBar : 0)
                .padding(.bottom, padsViewport ? bottomBar : 0)
                .overlay(alignment: .top) {
                    if padsViewport && !session.controlsVisible { toolbarMargin(height: topBar) }
                }
                .overlay(alignment: .bottom) {
                    if padsViewport && !session.controlsVisible { toolbarMargin(height: bottomBar) }
                }
                .ignoresSafeArea(.container, edges: isPhone ? .vertical : [])
        }
        .ignoresSafeArea(.keyboard)
        .overlay { ReaderOpeningOverlay(session: session) }
        .accessibilityAction(named: Text("Show or hide reading controls")) { session.toggleControls() }
        .overlay(alignment: .top) { ReaderTopOverlay(session: session) }
        .overlay(alignment: .bottom) {
            ReaderBottomOverlay(session: session, reservesToolbarSpace: reservesToolbarSpace, openContents: { showContents = true },
                openPreferences: { showPreferences = true }, openProgressJump: { showProgressJump = true })
        }
        .onPreferenceChange(ReaderBarHeights.self) { heights in
            // Keep the last measurement while controls are hidden so they can reserve space immediately.
            barHeights.merge(heights) { _, height in height }
        }
        .preferredColorScheme(readerColorScheme)
        .statusBarHidden(isPhone)
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
        .sheet(isPresented: $showPreferences) {
            BookReaderPreferencesView(session: session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // Keep the offer pending through dismissal until its button action is handled.
        .alert(item: Binding(get: { session.prompt }, set: { _ in })) { prompt in
            let percentage = Int((prompt.remote.percentage ?? 0)*100)
            switch prompt.kind {
            case .conflict:
                return Alert(title: Text("Choose a Reading Position"),
                    message: Text("On this device: \(Int(session.progression*100))%. On the server: \(percentage)%. Both positions have changed."),
                    primaryButton: .default(Text("Use Server Position")) { Task { await session.respond(to: prompt, with: .useServer) } },
                    secondaryButton: .default(Text("Keep and Upload Local Position")) { Task { await session.respond(to: prompt, with: .uploadLocal) } })
            case .approximate:
                return Alert(title: Text("Couldn’t Locate the Exact Server Position"),
                    message: Text("Jump to approximately \(percentage)%? Different readers may land on different paragraphs."),
                    primaryButton: .default(Text("Jump to Approximate Position")) { Task { await session.respond(to: prompt, with: .useServer) } },
                    secondaryButton: .cancel(Text("Keep Local Position")) { Task { await session.respond(to: prompt, with: .keepLocal) } })
            }
        }
        .errorAlert($session.error)
    }

    // The reserved margins sit outside Readium's view and use the same center tap rule.
    private func toolbarMargin(height: CGFloat) -> some View {
        GeometryReader { margin in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { point in
                    session.contentTapped(at: point, in: CGRect(origin: .zero, size: margin.size))
                }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct BookReaderPreferencesView: View {
    let session: ReaderSession

    var body: some View {
        NavigationStack {
            ReaderPreferencesView(settings: session.readerSettings, supportsScrolling: session.supportsScrolling,
                update: session.saveReaderSettings)
        }
    }
}
private struct EPUBProgressJumpView: View {
    private enum Target {
        case progression(Double)
        case chapter(ContentsItem)
    }

    let session: ReaderSession
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
    let session: ReaderSession
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

    let session: ReaderSession
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
