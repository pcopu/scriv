// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Scriv",
    platforms: [.macOS(.v14), .iOS(.v17), .macCatalyst(.v17)],
    products: [.library(name: "ScrivCore", targets: ["ScrivCore"])],
    targets: [.target(name: "ScrivCore")],
    swiftLanguageVersions: [.v5]
)
