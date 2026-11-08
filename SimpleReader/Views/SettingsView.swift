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
                Button { editing = true } label: { HStack { Text("Server and Account"); Spacer(); Text(store.settings.sync.username.isEmpty ? String(localized: "Not configured") : store.settings.sync.username).foregroundColor(.secondary) } }
                Text(store.settings.sync.enabled ? "Sync is on. Opening a book checks for progress. Closing it attempts to upload." : "Sync is off").font(.caption).foregroundColor(.secondary)
                Text(sync.status).font(.caption).foregroundColor(.secondary)
            }
            Section(header: Text("Reading")) { NavigationLink("Default Reading Settings", destination: ReaderPreferencesView(store: store, onChange: {})) }
            Section(header: Text("About")) {
                NavigationLink("About Simple Reader", destination: AboutView())
            }
        }.navigationTitle("Settings").sheet(isPresented: $editing) { SyncEditor(environment: environment) }
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
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(localized: "Unknown") }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? String(localized: "Unknown") }
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
                    Text("Your local book reader").font(.subheadline).foregroundColor(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            Section(header: Text("App Information")) {
                informationRow("Version", value: version)
                informationRow("Build", value: build)
                informationRow("Supported Formats", value: ["EPUB", "PDF"].formatted(.list(type: .and)))
                informationRow("Devices", value: ["iPhone", "iPad"].formatted(.list(type: .and)))
                informationRow("System Requirements", value: "iOS / iPadOS \(minimumOS)+")
            }
            Section(header: Text("Reading and Sync")) {
                Text("Import books from Files or download them from a Calibre OPDS library. Use KOReader Sync to sync reading positions across devices.")
                Text("Books and reading history stay on this device. Only the reading position is synced. Use the same book file on both devices. By default, KOReader matches files by content. Filename matching requires identical filenames.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Section(header: Text("Open Source")) {
                informationRow("App License", value: "AGPL-3.0-or-later")
                NavigationLink("Licenses and Acknowledgments", destination: LicenseView())
            }
        }.navigationTitle("About").navigationBarTitleDisplayMode(.inline)
    }

    private func informationRow(_ title: LocalizedStringKey, value: String) -> some View {
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
                TextField("Sync Server Address", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Existing Account Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
                Toggle("Enable Sync", isOn: $enabled)
                Toggle("Match by Original Filename", isOn: $filenameMatching)
                Button { Task { await verify() } } label: { if checking { ProgressView() } else { Text("Verify Account") } }.disabled(checking)
                if !verification.isEmpty { Text(verification).foregroundColor(.secondary) }
                Text("Use the same server, account, and matching method in KOReader. You can register an account in KOReader.").font(.caption).foregroundColor(.secondary)
            }.navigationTitle("KOReader Sync")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Save") { save() }.disabled(checking) }
            }
        }.navigationViewStyle(.stack).task { do { password = try environment.accounts.syncPassword() } catch { self.error = error.localizedDescription } }.errorAlert($error)
    }
    private func verify() async {
        checking = true; defer { checking = false }
        do {
            try await environment.accounts.verifySync(address: address, username: username, password: password,
                enabled: enabled, filenameMatching: filenameMatching)
            verification = String(localized: "Authentication successful")
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
    private var notices: String { guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") else { return String(localized: "See the project’s open-source license notices.") }; return (try? String(contentsOf: url)) ?? "" }
    var body: some View { ScrollView { Text(notices).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle("Open-Source Licenses") }
}
