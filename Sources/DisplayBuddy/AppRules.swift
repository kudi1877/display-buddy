import AppKit
import Combine

/// Per-app brightness: when an app with a rule comes to the front, all linked
/// monitors switch to that app's brightness; switching to any other app goes
/// back to the normal brightness.
final class AppRules: ObservableObject {
    static let shared = AppRules()

    struct Rule: Codable, Identifiable, Equatable {
        var bundleID: String
        var name: String
        var brightness: Double
        var id: String { bundleID }
    }

    @Published var rules: [Rule] { didSet { save(); evaluate() } }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "appRules.enabled"); evaluate() }
    }
    /// The app that was in front before Display Buddy's own popover opened.
    @Published private(set) var lastApp: (bundleID: String, name: String)?
    @Published private(set) var activeRule: Rule?

    private var observer: NSObjectProtocol?
    private let ownBundleID = Bundle.main.bundleIdentifier

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "appRules.enabled") as? Bool ?? true
        if let data = defaults.data(forKey: "appRules"), let saved = try? JSONDecoder().decode([Rule].self, from: data) {
            rules = saved
        } else {
            rules = []
        }
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostChanged(to: app)
        }
        frontmostChanged(to: NSWorkspace.shared.frontmostApplication)
    }

    private func frontmostChanged(to app: NSRunningApplication?) {
        // Opening Display Buddy itself must not cancel the current app's rule.
        guard let app, let id = app.bundleIdentifier, id != ownBundleID else { return }
        lastApp = (id, app.localizedName ?? id)
        evaluate()
    }

    private func evaluate() {
        let rule = enabled ? rules.first { $0.bundleID == lastApp?.bundleID } : nil
        if rule != activeRule { activeRule = rule }
        let manager = DisplayManager.shared
        if manager.appOverride != rule?.brightness { manager.appOverride = rule?.brightness }
    }

    func hasRule(for bundleID: String) -> Bool { rules.contains { $0.bundleID == bundleID } }

    /// Adds a rule starting at the brightness currently on screen.
    func add(bundleID: String, name: String) {
        guard !hasRule(for: bundleID) else { return }
        rules.append(Rule(bundleID: bundleID, name: name, brightness: DisplayManager.shared.shownBrightness))
    }

    func addFromFinder() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            add(bundleID: id, name: name)
        }
    }

    func remove(_ rule: Rule) { rules.removeAll { $0.bundleID == rule.bundleID } }

    func setBrightness(_ value: Double, for bundleID: String) {
        guard let i = rules.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        rules[i].brightness = value
    }

    /// Brightness keys while a rule is active adjust that app's brightness.
    func stepActive(by delta: Double) -> Bool {
        guard let rule = activeRule else { return false }
        let manager = DisplayManager.shared
        setBrightness(min(max(rule.brightness + delta, manager.minBrightness), 100), for: rule.bundleID)
        return true
    }

    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(data, forKey: "appRules") }
    }
}
