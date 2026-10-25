import AppKit
import IOKit.pwr_mgt
import PresenceCore
import UserNotifications

/// Keeps the Mac (and optionally the screens) awake with one public IOKit
/// power assertion, the approach Lungo uses. Manual sessions, app triggers and
/// presentation mode each add a "hold"; the strictest one decides the assertion.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var state = KeepAwakeState()

    /// Mode for manual and app-triggered sessions.
    @Published var mode: KeepAwakeMode {
        didSet {
            defaults.set(mode.rawValue, forKey: "presence.keepAwake.mode")
            state.setUserMode(mode)
            applyAssertion()
        }
    }
    @Published var customMinutes: Int {
        didSet { defaults.set(customMinutes, forKey: "presence.keepAwake.customMinutes") }
    }
    /// "Until" time for the until-a-set-time duration, minutes after midnight.
    @Published var untilMinutes: Int {
        didSet { defaults.set(untilMinutes, forKey: "presence.keepAwake.untilMinutes") }
    }
    /// Duration used by the keyboard shortcut and the main toggle.
    @Published var lastDuration: KeepAwakeDuration {
        didSet {
            if let data = try? JSONEncoder().encode(lastDuration) { defaults.set(data, forKey: "presence.keepAwake.lastDuration") }
        }
    }
    @Published var notifyWhenEnded: Bool {
        didSet {
            defaults.set(notifyWhenEnded, forKey: "presence.keepAwake.notify")
            if notifyWhenEnded { Self.requestNotificationPermission() }
        }
    }

    /// Called whenever "is anything keeping the Mac awake" changes (menu bar icon).
    var onActiveChange: ((Bool) -> Void)?

    private let defaults = UserDefaults.standard
    private var assertionID: IOPMAssertionID = 0
    private var assertionMode: KeepAwakeMode?
    private var expiryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        defaults.register(defaults: [
            "presence.keepAwake.mode": KeepAwakeMode.display.rawValue,
            "presence.keepAwake.customMinutes": 90,
            "presence.keepAwake.untilMinutes": 18 * 60,
            "presence.keepAwake.notify": true,
        ])
        mode = KeepAwakeMode(rawValue: defaults.string(forKey: "presence.keepAwake.mode") ?? "") ?? .display
        customMinutes = defaults.integer(forKey: "presence.keepAwake.customMinutes")
        untilMinutes = defaults.integer(forKey: "presence.keepAwake.untilMinutes")
        notifyWhenEnded = defaults.bool(forKey: "presence.keepAwake.notify")
        if let data = defaults.data(forKey: "presence.keepAwake.lastDuration"),
           let saved = try? JSONDecoder().decode(KeepAwakeDuration.self, from: data) {
            lastDuration = saved
        } else {
            lastDuration = .indefinitely
        }
    }

    // MARK: Lifecycle

    func start() {
        guard wakeObserver == nil else { return }
        // Timers don't fire while the Mac sleeps; catch up on waking.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.checkExpiry() }
    }

    /// Ends every session and releases the assertion (module disabled, app quit).
    func stop() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        state.removeAll()
        update()
    }

    // MARK: Sessions

    var manualHold: KeepAwakeHold? { state.hold(for: .manual) }
    var isManualOn: Bool { manualHold != nil }

    var customDuration: KeepAwakeDuration { .custom(minutes: customMinutes) }
    var untilDuration: KeepAwakeDuration { .until(hour: untilMinutes / 60, minute: untilMinutes % 60) }

    func startManual(_ duration: KeepAwakeDuration) {
        lastDuration = duration
        state.activate(.manual, mode: mode, deadline: duration.deadline(from: Date()))
        if duration != .indefinitely, notifyWhenEnded { Self.requestNotificationPermission() }
        update()
    }

    func stopManual() {
        state.deactivate(.manual)
        update()
    }

    func toggleManual() {
        if isManualOn { stopManual() } else { startManual(lastDuration) }
    }

    func hold(_ source: KeepAwakeSource, mode: KeepAwakeMode? = nil) {
        state.activate(source, mode: mode ?? self.mode, deadline: nil)
        update()
    }

    func release(_ source: KeepAwakeSource) {
        guard state.hold(for: source) != nil else { return }
        state.deactivate(source)
        update()
    }

    /// Battery fell below the user's limit: end manual and app sessions.
    func endForLowBattery(percent: Int) {
        let ended = state.endForLowBattery()
        guard !ended.isEmpty else { return }
        update()
        notify(title: "Keep Awake turned off", body: "Battery is at \(percent)%.")
    }

    func remaining(now: Date = Date()) -> TimeInterval? { state.remaining(for: .manual, now: now) }

    /// Plain-language description of what keeps the Mac awake right now.
    var reasonText: String? {
        var parts: [String] = []
        if state.hold(for: .presentation) != nil { parts.append("presentation mode") }
        for case .app(let id) in state.holds.keys {
            parts.append(AppTriggers.shared.name(for: id))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Assertion

    private func update() {
        checkExpiry(scheduleOnly: true)
        applyAssertion()
        onActiveChange?(state.isActive)
    }

    private func checkExpiry(scheduleOnly: Bool = false) {
        if !scheduleOnly {
            let expired = state.expire(now: Date())
            if expired.contains(.manual), notifyWhenEnded {
                notify(title: "Keep Awake ended", body: "Your Mac can sleep normally again.")
            }
            if !expired.isEmpty {
                applyAssertion()
                onActiveChange?(state.isActive)
            }
        }
        expiryTimer?.invalidate()
        expiryTimer = nil
        if let deadline = state.nextDeadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in self?.checkExpiry() }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        }
    }

    /// Exactly one assertion: swap to the new kind before releasing the old one,
    /// so there is never a gap where the Mac could fall asleep.
    private func applyAssertion() {
        let wanted = state.effectiveMode
        guard wanted != assertionMode else { return }
        var newID: IOPMAssertionID = 0
        if let wanted {
            let type = (wanted == .display ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep) as CFString
            let name = "Display Buddy Keep Awake" as CFString
            let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &newID)
            if result != kIOReturnSuccess {
                NSLog("Display Buddy: keep-awake assertion failed: \(result)")
                newID = 0
            }
        }
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        assertionID = newID
        assertionMode = newID != 0 ? wanted : nil
    }

    // MARK: Notifications

    /// UserNotifications only works from the bundled app, not `swift run`.
    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        guard Self.canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
