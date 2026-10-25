import AppKit

/// Runs AppleScript in-process (no `osascript` child process) on one serial
/// queue, so a permission prompt never freezes the menu.
enum AppleScript {
    enum Failure: Error, Equatable {
        /// The user denied (or hasn't granted) Automation access to System Events.
        case notAuthorized
        /// macOS asked for permission and nobody answered within two minutes.
        case promptUnanswered
        case failed(code: Int, message: String)

        var needsPermission: Bool { self == .notAuthorized || self == .promptUnanswered }

        var message: String {
            switch self {
            case .notAuthorized:
                return "Display Buddy isn't allowed to control System Events. Turn it on in System Settings → Privacy & Security → Automation."
            case .promptUnanswered:
                return "macOS is asking whether Display Buddy may control System Events. Click OK in that prompt (or allow it in System Settings → Privacy & Security → Automation), then try again."
            case .failed(_, let message):
                return message
            }
        }
    }

    private static let queue = DispatchQueue(label: "DisplayBuddy.AppleScript")

    static func run(_ source: String) async -> Result<NSAppleEventDescriptor, Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let result, error == nil {
                    continuation.resume(returning: .success(result))
                    return
                }
                let code = (error?[NSAppleScript.errorNumber] as? Int) ?? -1
                let message = (error?[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)"
                // -1743: not authorised; -1744: would need to ask, but can't;
                // -1712: timed out, which is what an unanswered permission prompt gives.
                let failure: Failure
                switch code {
                case -1743, -1744: failure = .notAuthorized
                case -1712: failure = .promptUnanswered
                default: failure = .failed(code: code, message: message)
                }
                continuation.resume(returning: .failure(failure))
            }
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Dock and menu bar auto-hide through System Events' scriptable Dock
/// preferences: a public interface that applies at once, without restarting the Dock.
enum DockMenuBar {
    static func read() async -> Result<(dock: Bool, menuBar: Bool), AppleScript.Failure> {
        let result = await AppleScript.run(
            "tell application \"System Events\" to tell dock preferences to get {autohide, autohide menu bar}")
        return result.flatMap { list in
            guard list.numberOfItems == 2, let dock = list.atIndex(1), let menu = list.atIndex(2) else {
                return .failure(.failed(code: -1, message: "System Events gave an unexpected answer."))
            }
            return .success((dock.booleanValue, menu.booleanValue))
        }
    }

    static func set(dock: Bool, menuBar: Bool) async -> Result<Void, AppleScript.Failure> {
        let script = """
        tell application "System Events" to tell dock preferences
            set autohide to \(dock)
            set autohide menu bar to \(menuBar)
        end tell
        """
        return await AppleScript.run(script).map { _ in () }
    }
}

/// The system alert (beep) volume, 0...100, via Standard Additions. This
/// talks to our own process only, so it needs no Automation permission.
enum AlertVolume {
    static func read() async -> Int? {
        guard case .success(let value) = await AppleScript.run("alert volume of (get volume settings)") else { return nil }
        return Int(value.int32Value)
    }

    static func set(_ volume: Int) async -> Bool {
        let clamped = min(max(volume, 0), 100)
        if case .success = await AppleScript.run("set volume alert volume \(clamped)") { return true }
        return false
    }
}
