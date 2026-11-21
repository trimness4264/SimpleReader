// swift-tools-version: 5.9
import PackageDescription

// Exercise the same non-UI sources on the host, without launching a reader.
let package = Package(
    name: "SimpleReaderLogic",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(
            name: "SimpleReader",
            dependencies: ["SwiftSoup"],
            path: "SimpleReader",
            exclude: ["App", "Views", "Reader", "Resources", "Services/BookImportService.swift",
                      "Services/DownloadManager.swift", "Services/ReadiumService.swift"],
            sources: ["Models", "Persistence", "Services/BookHashing.swift", "Services/HTTPClient.swift",
                      "Services/KOReaderSyncClient.swift", "Services/SyncCoordinator.swift", "Services/SyncPolicy.swift",
                      "Services/OPDSClient.swift", "Services/OPDSCatalogSession.swift",
                      "Services/EPUBSpine.swift"]
        ),
        .testTarget(name: "SimpleReaderTests", dependencies: ["SimpleReader"], path: "Tests/Logic")
    ]
)
