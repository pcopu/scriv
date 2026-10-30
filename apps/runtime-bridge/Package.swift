// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "ScrivRuntimeCompanion", platforms: [.macOS(.v14)], products: [.executable(name: "ScrivRuntimeCompanion", targets: ["ScrivRuntimeCompanion"])], dependencies: [.package(path: "../mac")], targets: [.executableTarget(name: "ScrivRuntimeCompanion", dependencies: [.product(name: "ScrivCore", package: "mac")])], swiftLanguageVersions: [.v5])
