import AppKit
import Carbon.HIToolbox
import PresenceCore

/// The Keep Awake + Presentation Mode module. One switch turns all of it on or
/// off; while off nothing from it is shown, observed, scheduled or asserted.
/// Everything outside this folder only calls `start()`, `prepareToQuit` and
/// `shutdown()`, so the display features don't depend on it.
@MainActor
final class Presence: ObservableObject {
    static let shared = Presence()

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "presence.enabled")
            if enabled { startServices() } else { stopServices() }
            Hotkeys.shared.reload()
        }
    }

    /// Menu bar icon "active" badge.
    var onActiveChange: ((Bool) -> Void)? {
        didSet { KeepAwake.shared.onActiveChange = { [weak self] _ in self?.reportActive() } }
    }

    private var servicesRunning = false

    private init() {
        UserDefaults.standard.register(defaults: ["presence.enabled": false])
        enabled = UserDefaults.standard.bool(forKey: "presence.enabled")
    }

    /// At launch. A crash-left presentation snapshot is restored even when the
    /// module is switched off, so the Mac is never left changed.
    func start() {
        Task { await PresentationMode.shared.recoverIfNeeded() }
        if enabled { startServices() }
    }

    /// Before the app quits: put presentation changes back first.
    func prepareToQuit(_ done: @escaping () -> Void) {
        PresentationMode.shared.prepareToQuit(done)
    }

    /// Last thing before quitting: release the power assertion.
    func shutdown() {
        servicesRunning = false
        finishStopping()
    }

    var isActive: Bool { KeepAwake.shared.state.isActive || PresentationMode.shared.isOn }

    /// ⌃⌥K Keep Awake, ⌃⌥P Presentation Mode (only while the module is on).
    var hotkeyBindings: [(Int, () -> Void)] {
        guard enabled else { return [] }
        return [
            (kVK_ANSI_K, { KeepAwake.shared.toggleManual() }),
            (kVK_ANSI_P, { MainActor.assumeIsolated { PresentationMode.shared.toggle() } }),
        ]
    }

    private func startServices() {
        guard !servicesRunning else { return }
        servicesRunning = true
        KeepAwake.shared.start()
        AppTriggers.shared.start()
        PowerWatcher.shared.start()
        reportActive()
    }

    private func stopServices() {
        guard servicesRunning else { return }
        servicesRunning = false
        let presentation = PresentationMode.shared
        if presentation.isOn {
            // Restore first; the assertion is released afterwards.
            Task {
                await presentation.turnOff()
                self.finishStopping()
            }
        } else {
            finishStopping()
        }
    }

    private func finishStopping() {
        ShareArea.shared.stop()
        AppTriggers.shared.stop()
        PowerWatcher.shared.stop()
        KeepAwake.shared.stop()
        reportActive()
    }

    func reportActive() {
        onActiveChange?(isActive)
    }
}
