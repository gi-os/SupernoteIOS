// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SupernoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NoteKit", targets: ["NoteKit"]),
        .library(name: "SyncKit", targets: ["SyncKit"]),
        .executable(name: "snsync", targets: ["snsync"]),
    ],
    dependencies: [
        // CryptoKit on Apple platforms, swift-crypto on Linux (CLI + CI).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "4.0.0"),
    ],
    targets: [
        .target(name: "NoteKit"),
        .target(
            name: "SyncKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ]
        ),
        .executableTarget(name: "snsync", dependencies: ["NoteKit", "SyncKit"]),
        .testTarget(name: "NoteKitTests", dependencies: ["NoteKit", "SyncKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SyncKitTests", dependencies: ["SyncKit"]),
    ]
)
