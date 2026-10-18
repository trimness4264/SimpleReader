import SwiftUI

@MainActor final class AppEnvironment {
    let store: LibraryStore
    let http = HTTPClient()
    let readium = ReadiumService()
    let importer: BookImportService
    let sharedImports: SharedBookImportCoordinator
    let downloads: DownloadManager
    let opds: OPDSClient
    let sync: SyncCoordinator
    init(store: LibraryStore? = nil, transfer: DownloadManager.Transfer? = nil) throws {
        self.store = try store ?? LibraryStore()
        importer = BookImportService(store: self.store, readium: readium)
        sharedImports = SharedBookImportCoordinator(importer: importer)
        downloads = DownloadManager(http: http, importer: importer, transfer: transfer)
        opds = OPDSClient(http: http)
        sync = SyncCoordinator(store: self.store, http: http)
    }
}
@MainActor final class Bootstrap: ObservableObject {
    let environment: AppEnvironment?
    let error: String?
    init() {
        do { environment = try AppEnvironment(); error = nil }
        catch { environment = nil; self.error = error.localizedDescription }
    }
}
@main struct SimpleReaderApp: App {
    @StateObject private var bootstrap = Bootstrap()
    var body: some Scene {
        WindowGroup {
            if let environment = bootstrap.environment { RootView(environment: environment) }
            else {
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                    Text("书库暂时无法打开").font(.title2)
                    Text(bootstrap.error ?? "未知错误").font(.callout)
                    Text("请重新启动应用。现有数据会保留。").foregroundColor(.secondary)
                }.padding()
            }
        }
    }
}
