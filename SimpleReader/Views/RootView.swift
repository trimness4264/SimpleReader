import SwiftUI

struct RootView: View {
    let environment: AppEnvironment
    @ObservedObject private var sharedImports: SharedBookImportCoordinator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    init(environment: AppEnvironment) {
        self.environment = environment
        sharedImports = environment.sharedImports
    }
    var body: some View {
        content
            .onOpenURL { url in
                guard url.isFileURL else { return }
                selectedTab = 0
                sharedImports.receive(url)
            }
            .task { _ = sharedImports.recoverInbox() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { sharedImports.recoverInbox() }
            }
            .onChange(of: sharedImports.pendingCount) { count in
                if count > 0 { selectedTab = 0 }
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
            if #available(iOS 16.0, *) {
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack { selectedContent }
                }
                .navigationSplitViewStyle(.balanced)
                // iPadOS 17 can retain pushed destinations in the split view itself.
                // Reset the whole navigation container when switching sidebar sections.
                .id(selectedTab)
            } else {
                NavigationView {
                    sidebar
                    selectedContent.id(selectedTab)
                }.navigationViewStyle(.columns)
            }
        } else {
            TabView(selection: $selectedTab) {
                NavigationView { LibraryView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("Library", systemImage: "books.vertical") }.tag(0)
                NavigationView { ServersView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("Online Library", systemImage: "network") }.tag(1)
                NavigationView { SettingsView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
            }
        }
    }
    private var sidebar: some View {
        List {
            sidebarButton("Library", systemImage: "books.vertical", tab: 0)
            sidebarButton("Online Library", systemImage: "network", tab: 1)
            sidebarButton("Settings", systemImage: "gearshape", tab: 2)
        }.listStyle(.sidebar).navigationTitle("Simple Reader")
    }
    private func sidebarButton(_ title: LocalizedStringKey, systemImage: String, tab: Int) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: systemImage).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
        .listRowBackground(selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
    @ViewBuilder private var selectedContent: some View {
        switch selectedTab {
        case 1: ServersView(environment: environment)
        case 2: SettingsView(environment: environment)
        default: LibraryView(environment: environment)
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
