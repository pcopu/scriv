// Read-only native acceptance evidence. Does not launch, install, send events,
// read documents/credentials, or require Accessibility/Automation permissions.
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass the expected installed Scriv.app path.") }
let expected = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
let candidates = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "app.scriv.uikit" && !$0.isTerminated }
guard candidates.count == 1, let app = candidates.first,
      let bundle = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath(), bundle == expected,
      let executable = app.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
      executable == expected.appendingPathComponent("Contents/MacOS/Scriv"),
      let launched = app.launchDate else { fatalError("Expected exactly one running Scriv at the installed acceptance path. Preserve evidence; do not launch another copy.") }
let result: [String: Any] = ["pid": app.processIdentifier, "launchedAt": launched.timeIntervalSince1970,
                            "capturedAt": Date().timeIntervalSince1970, "bundleID": app.bundleIdentifier!,
                            "bundlePath": bundle.path, "executablePath": executable.path]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
