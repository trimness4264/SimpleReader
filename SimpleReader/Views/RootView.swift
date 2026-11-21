import SwiftUI

struct RootView: View {
    private enum Tab: Hashable { case library, onlineLibrary, settings }

    let environment: AppEnvironment
    @ObservedObject private var sharedImports: SharedBookImportCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = Tab.library
    init(environment: AppEnvironment) {
        self.environment = environment
        sharedImports = environment.sharedImports
    }
    var body: some View {
        content
            .onOpenURL { url in
                guard url.isFileURL else { return }
                selectedTab = .library
                sharedImports.receive(url)
            }
            .task {
                sharedImports.recoverInbox()
                environment.sync.start()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    sharedImports.recoverInbox()
                    environment.sync.retryPending()
                }
            }
            .onChange(of: sharedImports.pendingCount) { _, count in
                if count > 0 { selectedTab = .library }
            }
            .safeAreaInset(edge: .bottom) {
                if sharedImports.pendingCount > 0 {
                    HStack { ProgressView(); Text("Importing shared book…") }
                        .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .alert(sharedImports.error == nil ? "Book Imported" : "Couldn’t Complete Action", isPresented: Binding(get: {
                sharedImports.pendingCount == 0 && (sharedImports.message != nil || sharedImports.error != nil)
            }, set: { if !$0 { sharedImports.message = nil; sharedImports.error = nil } })) {
                Button("OK", role: .cancel) { sharedImports.message = nil; sharedImports.error = nil }
            } message: { Text(sharedImports.error ?? sharedImports.message ?? "") }
    }
    @ViewBuilder private var content: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                sidebar
            } detail: {
                tabContent(selectedTab)
            }
            .navigationSplitViewStyle(.balanced)
            // iPadOS 17 can retain pushed destinations in the split view itself.
            // Reset the whole navigation container when switching sidebar sections.
            .id(selectedTab)
        } else {
            TabView(selection: $selectedTab) {
                tabContent(.library).tabItem { Label("Library", systemImage: "books.vertical") }.tag(Tab.library)
                tabContent(.onlineLibrary).tabItem { Label("Online Library", systemImage: "network") }.tag(Tab.onlineLibrary)
                tabContent(.settings).tabItem { Label("Settings", systemImage: "gearshape") }.tag(Tab.settings)
            }
        }
    }
    private var sidebar: some View {
        List {
            sidebarButton("Library", systemImage: "books.vertical", tab: .library)
            sidebarButton("Online Library", systemImage: "network", tab: .onlineLibrary)
            sidebarButton("Settings", systemImage: "gearshape", tab: .settings)
        }.listStyle(.sidebar).navigationTitle("Simple Reader")
    }
    private func sidebarButton(_ title: LocalizedStringKey, systemImage: String, tab: Tab) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
        .listRowBackground(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
    @ViewBuilder private func tabContent(_ tab: Tab) -> some View {
        switch tab {
        case .library: NavigationStack { LibraryView(environment: environment) }
        case .onlineLibrary: ServersView(environment: environment)
        case .settings: NavigationStack { SettingsView(environment: environment) }
        }
    }
}
struct ErrorAlert: ViewModifier {
    @Binding var error: String?
    func body(content: Content) -> some View {
        content.alert("Couldn’t Complete Action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
extension View { func errorAlert(_ error: Binding<String?>) -> some View { modifier(ErrorAlert(error: error)) } }
