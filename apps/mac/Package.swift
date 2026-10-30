// swift-tools-version: 5.10
import PackageDescription

var products: [Product] = [.library(name: "ScrivCore", targets: ["ScrivCore"])]
var targets: [Target] = [
    .target(name: "ScrivCore"),
    .testTarget(name: "ScrivCoreTests", dependencies: ["ScrivCore"])
]
#if os(macOS)
products.append(.executable(name: "Scriv", targets: ["ScrivApp"]))
targets.append(.executableTarget(name: "ScrivApp", dependencies: ["ScrivCore"], resources: [.process("Resources")]))
targets.append(.testTarget(name: "ScrivAppTests", dependencies: ["ScrivApp", "ScrivCore"]))
#endif

let package = Package(
    name: "Scriv",
    platforms: [.macOS(.v14), .iOS(.v17), .macCatalyst(.v17)],
    products: products,
    targets: targets,
    swiftLanguageVersions: [.v5]
)
