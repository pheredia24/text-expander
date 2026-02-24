// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TextExpander",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "TextExpander", targets: ["TextExpander"]),
    ],
    targets: [
        .executableTarget(
            name: "TextExpander"
        ),
        .testTarget(
            name: "TextExpanderTests",
            dependencies: ["TextExpander"]
        ),
    ]
)
