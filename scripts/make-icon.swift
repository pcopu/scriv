import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass the output iconset directory.") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("design/icon/scriv-ribbon-master.png")
guard FileManager.default.fileExists(atPath: master.path) else { fatalError("Approved Ribbon master is missing.") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = String(size * scale)
        let suffix = scale == 2 ? "@2x" : ""
        let target = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-z", pixels, pixels, master.path, "--out", target.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { fatalError("Could not resample approved Ribbon master.") }
    }
}
