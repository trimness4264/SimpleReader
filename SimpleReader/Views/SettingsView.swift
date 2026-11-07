import SwiftUI

struct SettingsView: View {
    let environment: AppEnvironment
    @ObservedObject private var store: LibraryStore
    @ObservedObject private var sync: SyncCoordinator
    @State private var editing = false
    init(environment: AppEnvironment) { self.environment = environment; store = environment.store; sync = environment.sync }
    var body: some View {
        Form {
            Section(header: Text("KOReader Sync")) {
                Button { editing = true } label: { HStack { Text("服务器与账号"); Spacer(); Text(store.settings.sync.username.isEmpty ? "未设置" : store.settings.sync.username).foregroundColor(.secondary) } }
                Text(store.settings.sync.enabled ? "已启用：打开图书时拉取，关闭时尝试上传。" : "同步未启用").font(.caption).foregroundColor(.secondary)
                Text(sync.status).font(.caption).foregroundColor(.secondary)
            }
            Section(header: Text("阅读")) { NavigationLink("默认阅读设置", destination: ReaderPreferencesView(store: store, onChange: {})) }
            Section(header: Text("关于")) {
                NavigationLink("关于 Simple Reader", destination: AboutView())
            }
        }.navigationTitle("设置").sheet(isPresented: $editing) { SyncEditor(environment: environment) }
    }
}
private struct AboutView: View {
    private var appIcon: UIImage? {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primaryIcon = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconName = (primaryIcon?["CFBundleIconFiles"] as? [String])?.last
        return iconName.flatMap { UIImage(named: $0) }
    }
    private var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Simple Reader" }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知" }
    private var minimumOS: String { Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String ?? "15.0" }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    if let icon = appIcon {
                        Image(uiImage: icon)
                            .resizable().scaledToFit()
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .accessibilityHidden(true)
                    }
                    Text(appName).font(.title2.bold())
                    Text("你的本地图书阅读器").font(.subheadline).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            Section(header: Text("应用信息")) {
                informationRow("版本", value: version)
                informationRow("构建号", value: build)
                informationRow("支持格式", value: "EPUB、PDF")
                informationRow("适用设备", value: "iPhone、iPad")
                informationRow("系统要求", value: "iOS / iPadOS \(minimumOS)+")
            }
            Section(header: Text("阅读与同步")) {
                Text("从文件导入图书，或连接 Calibre OPDS 书库下载；通过 KOReader Sync 在设备间同步阅读位置。")
                Text("图书与阅读记录保存在本机，同步只传输阅读位置。两端需要使用相同的图书文件；默认按 KOReader 内容摘要匹配，文件名模式需要两端文件名一致。")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section(header: Text("开源")) {
                informationRow("应用许可", value: "AGPL-3.0-or-later")
                NavigationLink("开源许可与致谢", destination: LicenseView())
            }
        }.navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    }

    private func informationRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }
}

#if DEBUG
private struct AboutView_Previews: PreviewProvider {
    static var previews: some View { NavigationView { AboutView() } }
}
#endif

private struct SyncEditor: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var address: String
    @State private var username: String
    @State private var password = ""
    @State private var enabled: Bool
    @State private var filenameMatching: Bool
    @State private var checking = false
    @State private var verification = ""
    @State private var error: String?
    init(environment: AppEnvironment) {
        self.environment = environment; let sync = environment.store.settings.sync
        _address = State(initialValue: sync.url.absoluteString); _username = State(initialValue: sync.username)
        _enabled = State(initialValue: sync.enabled); _filenameMatching = State(initialValue: sync.filenameMatching)
    }
    var body: some View {
        NavigationView {
            Form {
                TextField("同步服务器地址", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("已有账号用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("密码", text: $password)
                Toggle("启用同步", isOn: $enabled)
                Toggle("按原始文件名匹配", isOn: $filenameMatching)
                Button { Task { await verify() } } label: { if checking { ProgressView() } else { Text("验证账号") } }.disabled(checking)
                if !verification.isEmpty { Text(verification).foregroundColor(.secondary) }
                Text("无需修改 KOReader。请在 KOReader 中使用相同服务器、账号和匹配方式。账号可先在 KOReader 注册。").font(.caption).foregroundColor(.secondary)
            }.navigationTitle("KOReader Sync")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("保存") { save() }.disabled(checking) }
            }
        }.navigationViewStyle(.stack).task { do { password = try environment.accounts.syncPassword() } catch { self.error = error.localizedDescription } }.errorAlert($error)
    }
    private func verify() async {
        checking = true; defer { checking = false }
        do {
            try await environment.accounts.verifySync(address: address, username: username, password: password,
                enabled: enabled, filenameMatching: filenameMatching)
            verification = "认证成功"
        }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            try environment.accounts.saveSync(address: address, username: username, password: password,
                enabled: enabled, filenameMatching: filenameMatching)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
private struct LicenseView: View {
    private var notices: String { guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else { return "请参阅项目的开源许可说明。" }; return (try? String(contentsOf: url)) ?? "" }
    var body: some View { ScrollView { Text(notices).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle("开源许可") }
}
