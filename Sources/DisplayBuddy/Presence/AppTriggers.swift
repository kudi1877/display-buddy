import AppKit
import PresenceCore

/// Keeps the Mac awake while chosen apps (e.g. Keynote, Zoom) are running.
/// Watches NSWorkspace launch/quit notifications; no polling.
final class AppTriggers: ObservableObject {
    static let shared = AppTriggers()

    struct TriggerApp: Codable, Identifiable, Equatable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    @Published var apps: [TriggerApp] { didSet { save(); if isRunning { evaluateAll() } } }

    private var observers: [NSObjectProtocol] = []
    private var isRunning: Bool { !observers.isEmpty }
    private let key = "presence.keepAwake.apps"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode([TriggerApp].self, from: data) {
            apps = saved
        } else {
            apps = []
        }
    }

    func start() {
        guard !isRunning else { return }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let id = app.bundleIdentifier else { return }
                self?.evaluate(bundleID: id)
            })
        }
        evaluateAll()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        for case .app(let id) in KeepAwake.shared.state.holds.keys { KeepAwake.shared.release(.app(bundleID: id)) }
    }

    func name(for bundleID: String) -> String {
        apps.first { $0.bundleID == bundleID }?.name ?? bundleID
    }

    func isRunning(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }
    }

    private func evaluate(bundleID: String) {
        // Several copies of an app can run; stay awake until the last one quits.
        let wanted = apps.contains { $0.bundleID == bundleID } && isRunning(bundleID)
        let source = KeepAwakeSource.app(bundleID: bundleID)
        if wanted { KeepAwake.shared.hold(source) } else { KeepAwake.shared.release(source) }
    }

    private func evaluateAll() {
        // Drop holds for apps removed from the list, then check every listed app.
        for case .app(let id) in KeepAwake.shared.state.holds.keys where !apps.contains(where: { $0.bundleID == id }) {
            KeepAwake.shared.release(.app(bundleID: id))
        }
        apps.forEach { evaluate(bundleID: $0.bundleID) }
    }

    func add(bundleID: String, name: String) {
        guard !apps.contains(where: { $0.bundleID == bundleID }) else { return }
        apps.append(TriggerApp(bundleID: bundleID, name: name))
    }

    func remove(_ app: TriggerApp) { apps.removeAll { $0.bundleID == app.bundleID } }

    func addFromFinder() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            add(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: key) }
    }
}
