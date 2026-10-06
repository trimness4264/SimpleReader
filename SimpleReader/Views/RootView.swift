import SwiftUI

struct RootView: View {
    let environment: AppEnvironment
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var importError: String?
    var body: some View {
        content.onOpenURL { url in Task { do { _ = try await environment.importer.importBook(from: url) } catch { importError = error.localizedDescription } } }.errorAlert($importError)
    }
    @ViewBuilder private var content: some View {
        if sizeClass == .regular {
            NavigationView {
                List {
                    NavigationLink(destination: LibraryView(environment: environment)) { Label("书库", systemImage: "books.vertical") }
                    NavigationLink(destination: ServersView(environment: environment)) { Label("在线书库", systemImage: "network") }
                    NavigationLink(destination: DownloadsView(manager: environment.downloads)) { Label("下载", systemImage: "arrow.down.circle") }
                    NavigationLink(destination: SettingsView(environment: environment)) { Label("设置", systemImage: "gearshape") }
                }.listStyle(.sidebar).navigationTitle("Simple Reader")
                LibraryView(environment: environment)
            }
        } else {
            TabView {
                NavigationView { LibraryView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("书库", systemImage: "books.vertical") }
                NavigationView { ServersView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("在线书库", systemImage: "network") }
                NavigationView { DownloadsView(manager: environment.downloads) }.navigationViewStyle(.stack).tabItem { Label("下载", systemImage: "arrow.down.circle") }
                NavigationView { SettingsView(environment: environment) }.navigationViewStyle(.stack).tabItem { Label("设置", systemImage: "gearshape") }
            }.accentColor(Color(red: 0.19, green: 0.39, blue: 0.34))
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
