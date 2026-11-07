// swift-tools-version: 5.9
import PackageDescription

// Exercise the same non-UI sources on the host, without launching a reader.
let package = Package(
    name: "SimpleReaderLogic",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SimpleReader",
            path: "SimpleReader",
            exclude: ["App", "Views", "Reader", "Resources", "Services/BookImportService.swift",
                      "Services/DownloadManager.swift", "Services/ReadiumService.swift"],
            sources: ["Models", "Persistence", "Services/BookHashing.swift", "Services/HTTPClient.swift",
                      "Services/KOReaderSyncClient.swift", "Services/OPDSClient.swift", "Services/EPUBSpine.swift"]
        ),
        .testTarget(name: "SimpleReaderTests", dependencies: ["SimpleReader"], path: "Tests/Logic")
    ]
)
