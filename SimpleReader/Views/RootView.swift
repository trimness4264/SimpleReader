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
                    HStack { ProgressView(); Text("正在导入分享的图书…") }
                        .padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .alert(sharedImports.error == nil ? "图书已导入" : "操作未完成", isPresented: Binding(get: {
                sharedImports.pendingCount == 0 && (sharedImports.message != nil || sharedImports.error != nil)
            }, set: { if !$0 { sharedImports.message = nil; sharedImports.error = nil } })) {
                Button("好", role: .cancel) { sharedImports.message = nil; sharedImports.error = nil }
            } message: { Text(sharedImports.error ?? sharedImports.message ?? "") }
    }
    @ViewBuilder private var content: some View {
        if sizeClass == .regular {
            if #available(iOS 16.0, *) {
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack { selectedContent }.id(selectedTab)
                }.navigationSplitViewStyle(.balanced)
            } else {
                NavigationView {
                    sidebar
                    selectedContent.id(selectedTab)
                }.navigationViewStyle(.columns)
            }
        } else {
            TabView(selection: $selectedTab) {
                NavigationView { LibraryView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("书库", systemImage: "books.vertical") }.tag(0)
                NavigationView { ServersView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("在线书库", systemImage: "network") }.tag(1)
                NavigationView { SettingsView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("设置", systemImage: "gearshape") }.tag(2)
            }.accentColor(Color(red: 0.19, green: 0.39, blue: 0.34))
        }
    }
    private var sidebar: some View {
        List {
            sidebarButton("书库", systemImage: "books.vertical", tab: 0)
            sidebarButton("在线书库", systemImage: "network", tab: 1)
            sidebarButton("设置", systemImage: "gearshape", tab: 2)
        }.listStyle(.sidebar).navigationTitle("Simple Reader")
    }
    private func sidebarButton(_ title: String, systemImage: String, tab: Int) -> some View {
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
        content.alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}
extension View { func errorAlert(_ error: Binding<String?>) -> some View { modifier(ErrorAlert(error: error)) } }
