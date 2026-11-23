// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuickAlbum",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "QuickAlbumCore",
            targets: ["QuickAlbumCore"]
        )
    ],
    targets: [
        .target(
            name: "QuickAlbumCore",
            path: "QuickAlbum/Core"
        ),
        .testTarget(
            name: "QuickAlbumCoreTests",
            dependencies: ["QuickAlbumCore"],
            path: "QuickAlbumCoreTests"
        )
    ]
)
