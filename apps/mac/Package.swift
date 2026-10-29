// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Scriv",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ScrivCore", targets: ["ScrivCore"]), .executable(name: "Scriv", targets: ["ScrivApp"])],
    targets: [
        .target(name: "ScrivCore"),
        .executableTarget(name: "ScrivApp", dependencies: ["ScrivCore"], resources: [.process("Resources")]),
        .testTarget(name: "ScrivCoreTests", dependencies: ["ScrivCore"])
    ],
    swiftLanguageVersions: [.v5]
)
