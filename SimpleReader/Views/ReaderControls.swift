import SwiftUI

enum ReaderBar {
    case top, bottom, syncStatus
}

struct ReaderBarHeights: PreferenceKey {
    static let defaultValue: [ReaderBar: CGFloat] = [:]

    static func reduce(value: inout [ReaderBar: CGFloat], nextValue: () -> [ReaderBar: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private struct ReaderControlPreferences: DynamicProperty {
    @AppStorage("reader.showPageButtons") var showPageButtons = false
    @AppStorage("reader.showProgress") var showProgress = true
}

struct ReaderOpeningOverlay: View {
    let session: ReaderSession
    @State private var showRestorationProgress = false

    var body: some View {
        Group {
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
        .task(id: session.isRestoring) {
            showRestorationProgress = false
            guard session.isRestoring else { return }
            // A short pagination pass should not flash a loading screen over the page.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            showRestorationProgress = true
        }
    }
}

struct ReaderTopOverlay: View {
    let session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var closing = false

    var body: some View {
        topControls
            .background { measuredReaderBar(.top) }
            .modifier(ReaderBarVisibility(isVisible: session.controlsVisible, hiddenOffset: reduceMotion ? 0 : -8))
            .animation(readerControlsAnimation(reduceMotion: reduceMotion), value: session.controlsVisible)
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
            ReaderOptionsMenu(session: session)
        }.padding(.horizontal, 8).background(.regularMaterial)
    }
}

private struct ReaderOptionsMenu: View {
    let session: ReaderSession
    @ObservedObject private var sync: SyncCoordinator
    private var preferences = ReaderControlPreferences()

    init(session: ReaderSession) {
        self.session = session
        sync = session.sync
    }

    var body: some View {
        Menu {
            Text(session.syncMessage ?? sync.status)
            Button {
                Task { await session.synchronize() }
            } label: { Label("Sync Reading Progress", systemImage: "arrow.triangle.2.circlepath") }
            Toggle("Show Compact Progress Indicator", isOn: preferences.$showProgress)
            if !session.isScrolling { Toggle("Show Page Turn Buttons", isOn: preferences.$showPageButtons) }
            if let warning = session.bridgeWarning { Text(warning) }
            Button("Hide Reading Controls") { session.toggleControls() }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("More reading options")
    }
}

struct ReaderBottomOverlay: View {
    let session: ReaderSession
    let reservesToolbarSpace: Bool
    let openContents: () -> Void
    let openPreferences: () -> Void
    let openProgressJump: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var preferences = ReaderControlPreferences()

    init(session: ReaderSession, reservesToolbarSpace: Bool, openContents: @escaping () -> Void,
         openPreferences: @escaping () -> Void, openProgressJump: @escaping () -> Void) {
        self.session = session
        self.reservesToolbarSpace = reservesToolbarSpace
        self.openContents = openContents
        self.openPreferences = openPreferences
        self.openProgressJump = openProgressJump
    }

    var body: some View {
        VStack(spacing: 4) {
            ReaderSyncBanner(session: session)
            controls.disabled(!session.ready || session.isNavigating || session.isRestoring)
        }
        .background {
            if reservesToolbarSpace {
                measuredReaderBar(.bottom)
            } else if session.syncError != nil {
                measuredReaderBar(.syncStatus)
            }
        }
        .animation(readerControlsAnimation(reduceMotion: reduceMotion), value: session.controlsVisible)

    }

    @ViewBuilder private var controls: some View {
        if session.isScrolling {
            if session.controlsVisible {
                bottomControls.transition(readerControlsTransition(verticalOffset: 8, reduceMotion: reduceMotion))
            } else {
                compactProgress
            }
        } else {
            bottomControls
                .modifier(ReaderBarVisibility(isVisible: session.controlsVisible, hiddenOffset: reduceMotion ? 0 : 8))
                .overlay(alignment: .bottom) {
                    if !session.controlsVisible { compactProgress }
                }
        }
    }

    @ViewBuilder private var compactProgress: some View {
        if preferences.showProgress {
            ReaderProgressJumpButton(session: session, compact: true, openProgressJump: openProgressJump)
                .transition(.opacity)
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 12) {
            Button(action: openContents) { Image(systemName: "list.bullet").frame(width: 44, height: 44) }
                .accessibilityLabel("Contents")
            Spacer(minLength: 0)
            if preferences.showPageButtons && !session.isScrolling {
                Button { Task { await session.turn(forward: false) } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("Previous page")
            }
            ReaderProgressJumpButton(session: session, compact: false, openProgressJump: openProgressJump).layoutPriority(1)
            if preferences.showPageButtons && !session.isScrolling {
                Button { Task { await session.turn(forward: true) } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("Next page")
            }
            Spacer(minLength: 0)
            if session.bookFormat == .epub {
                Button(action: openPreferences) { Image(systemName: "textformat.size").frame(width: 44, height: 44) }
                    .accessibilityLabel("Reading Settings")
            } else {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).background(.regularMaterial)
    }
}

private struct ReaderSyncBanner: View {
    let session: ReaderSession
    @ObservedObject private var sync: SyncCoordinator
    @State private var showSyncStatus = false

    init(session: ReaderSession) {
        self.session = session
        sync = session.sync
    }

    var body: some View {
        Group {
            if session.syncError != nil {
                Button { showSyncStatus = true } label: {
                    Label("Sync failed. Tap for details.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption).padding(12).background(.regularMaterial, in: Capsule())
                }
            }
        }
        .alert("Sync Failed", isPresented: $showSyncStatus) {
            Button("Retry") { Task { await session.synchronize() } }
            Button("Close", role: .cancel) {}
        } message: { Text(session.syncMessage ?? sync.status) }
    }
}

private struct ReaderProgressJumpButton: View {
    let session: ReaderSession
    let compact: Bool
    let openProgressJump: () -> Void

    var body: some View {
        Button(action: openProgressJump) {
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
}

private struct ReaderBarVisibility: ViewModifier {
    let isVisible: Bool
    let hiddenOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : hiddenOffset)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

private func measuredReaderBar(_ bar: ReaderBar) -> some View {
    GeometryReader { geometry in
        Color.clear.preference(key: ReaderBarHeights.self, value: [bar: geometry.size.height])
    }
}

private func readerControlsAnimation(reduceMotion: Bool) -> Animation {
    .easeInOut(duration: reduceMotion ? 0.15 : 0.25)
}

private func readerControlsTransition(verticalOffset: CGFloat, reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .opacity.combined(with: .offset(y: verticalOffset))
}
