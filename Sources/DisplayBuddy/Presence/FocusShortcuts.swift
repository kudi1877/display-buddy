import Foundation
import PresenceCore

/// Do Not Disturb through two shortcuts the user makes in the Shortcuts app
/// (Set Focus on / off), run with Apple's `shortcuts` command-line tool.
/// There is no public API for apps to switch Focus on or off.
enum FocusShortcuts {
    struct RunResult {
        var succeeded: Bool
        var output: String
        var error: String
    }

    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

    /// Names of the user's shortcuts, or nil if the tool couldn't be run.
    static func list() async -> Set<String>? {
        let result = await run(arguments: ["list"], timeout: 20)
        guard result.succeeded else { return nil }
        return Set(result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Runs a shortcut; when `captureOutput` is set, returns what it outputs (e.g. the current Focus).
    static func run(shortcut name: String, captureOutput: Bool = false) async -> RunResult {
        guard captureOutput else { return await run(arguments: ["run", name], timeout: 30) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("displaybuddy-focus-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        var result = await run(arguments: ["run", name, "--output-path", file.path, "--output-type", "public.plain-text"], timeout: 30)
        result.output = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return result
    }

    private static func run(arguments: [String], timeout: TimeInterval) async -> RunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RunResult(succeeded: false, output: "", error: error.localizedDescription))
                    return
                }
                // A shortcut waiting on a dialog must not hang presentation mode.
                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let output = out.fileHandleForReading.readDataToEndOfFile()
                let errors = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: RunResult(
                    succeeded: process.terminationStatus == 0 && process.terminationReason == .exit,
                    output: String(decoding: output, as: UTF8.self),
                    error: String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
