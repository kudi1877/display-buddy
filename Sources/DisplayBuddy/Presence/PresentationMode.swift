import AppKit
import PresenceCore

/// One click makes the screens presentation-safe; one click puts every changed
/// setting back to its exact previous value. Before each change the previous
/// value is written to disk, so a crash or force-quit is undone at next launch.
@MainActor
final class PresentationMode: ObservableObject {
    static let shared = PresentationMode()

    struct Issue: Identifiable, Equatable {
        enum Action: Equatable { case openAutomationSettings, openPresenceSettings, retryRestore }
        let id = UUID()
        var text: String
        var action: Action?
    }

    enum CoverStyle: String, CaseIterable, Identifiable {
        case wallpaper, color
        var id: String { rawValue }
        var title: String { self == .wallpaper ? "Current wallpaper" : "Solid colour" }
    }

    @Published private(set) var isOn = false { didSet { Presence.shared.reportActive() } }
    @Published private(set) var isBusy = false
    @Published private(set) var issues: [Issue] = []
    @Published private(set) var notice: String?

    @Published var enabledSteps: Set<PresentationStep> {
        didSet { defaults.set(enabledSteps.map(\.rawValue).sorted(), forKey: "presence.presentation.steps") }
    }
    @Published var coverStyle: CoverStyle {
        didSet { defaults.set(coverStyle.rawValue, forKey: "presence.presentation.coverStyle") }
    }
    @Published var neutralColor: NeutralColor {
        didSet { defaults.set(neutralColor.rawValue, forKey: "presence.presentation.color") }
    }
    @Published var focusOnShortcut: String { didSet { defaults.set(focusOnShortcut, forKey: "presence.focus.on") } }
    @Published var focusOffShortcut: String { didSet { defaults.set(focusOffShortcut, forKey: "presence.focus.off") } }
    /// Optional: a shortcut that outputs the current Focus, so a Focus that was
    /// already on is left alone.
    @Published var focusStatusShortcut: String { didSet { defaults.set(focusStatusShortcut, forKey: "presence.focus.status") } }

    static let defaultSteps: Set<PresentationStep> = [.keepAwake, .focus, .dockAndMenuBar, .desktopCover]

    private let defaults = UserDefaults.standard
    private let store = SnapshotStore(url: SnapshotStore.defaultURL())
    private var snapshot: PresentationSnapshot?

    private init() {
        defaults.register(defaults: [
            "presence.presentation.steps": Self.defaultSteps.map(\.rawValue),
            "presence.presentation.coverStyle": CoverStyle.wallpaper.rawValue,
            "presence.presentation.color": NeutralColor.graphite.rawValue,
            "presence.focus.on": "Display Buddy Focus On",
            "presence.focus.off": "Display Buddy Focus Off",
            "presence.focus.status": "",
        ])
        enabledSteps = Set((defaults.stringArray(forKey: "presence.presentation.steps") ?? []).compactMap(PresentationStep.init))
        coverStyle = CoverStyle(rawValue: defaults.string(forKey: "presence.presentation.coverStyle") ?? "") ?? .wallpaper
        neutralColor = NeutralColor(rawValue: defaults.string(forKey: "presence.presentation.color") ?? "") ?? .graphite
        focusOnShortcut = defaults.string(forKey: "presence.focus.on") ?? ""
        focusOffShortcut = defaults.string(forKey: "presence.focus.off") ?? ""
        focusStatusShortcut = defaults.string(forKey: "presence.focus.status") ?? ""
    }

    /// True while there is anything to put back (including a failed earlier restore).
    var hasPendingRestore: Bool { isOn || store.exists }

    func toggle() {
        Task { if isOn { await turnOff() } else { await turnOn() } }
    }

    func dismissNotice() { notice = nil }

    // MARK: Turn on

    func turnOn() async {
        guard !isOn, !isBusy else { return }
        // A snapshot left from a session that didn't finish restoring must be
        // put back first, or its "before" values would be overwritten.
        if store.exists { await recoverIfNeeded() }
        guard !store.exists else { return }

        isBusy = true
        issues = []
        notice = nil
        var snap = PresentationSnapshot(startedAt: Date())
        guard persist(snap) else { isBusy = false; return }
        snapshot = snap
        isOn = true

        for step in PresentationStep.allCases where enabledSteps.contains(step) {
            await apply(step, to: &snap)
            snapshot = snap
        }
        persist(snap)
        isBusy = false
        // Optional: start sharing an area too. It changes no system setting,
        // so it isn't part of the saved state.
        await ShareArea.shared.startForPresentation()
    }

    /// Records what the step will change and marks it applied *before* changing
    /// anything, then makes the change. Restoring a step that never got applied
    /// is harmless; missing one that was applied is not.
    private func apply(_ step: PresentationStep, to snap: inout PresentationSnapshot) async {
        switch step {
        case .keepAwake:
            snap.markApplied(step)
            persist(snap)
            KeepAwake.shared.hold(.presentation, mode: .display)

        case .focus:
            await applyFocus(to: &snap)

        case .dockAndMenuBar:
            switch await DockMenuBar.read() {
            case .failure(let failure):
                report(failure, step: step)
            case .success(let current):
                snap.dockMenuBar = DockMenuBarState(dockAutohide: current.dock, menuBarAutohide: current.menuBar)
                snap.markApplied(step)
                persist(snap)
                if case .failure(let failure) = await DockMenuBar.set(dock: true, menuBar: true) {
                    report(failure, step: step)
                }
            }

        case .alertVolume:
            guard let volume = await AlertVolume.read() else {
                issues.append(Issue(text: "Couldn't read the alert volume, so alert sounds were left on."))
                return
            }
            snap.alertVolume = volume
            snap.markApplied(step)
            persist(snap)
            _ = await AlertVolume.set(0)

        case .displayPreset:
            let m = DisplayManager.shared
            snap.display = DisplayState(brightness: m.brightness, adaptive: m.adaptiveBrightness,
                                        colorMode: m.colorMode.rawValue, manualKelvin: m.manualKelvin)
            snap.markApplied(step)
            persist(snap)
            m.adaptiveBrightness = false
            m.colorMode = .off
            m.brightness = 100

        case .wallpaper:
            let captured = Wallpaper.capture()
            guard let saved = captured.saved else {
                issues.append(Issue(text: captured.problem ?? "The wallpaper was left as it is."))
                return
            }
            snap.wallpapers = saved
            snap.markApplied(step)
            persist(snap)
            do {
                try Wallpaper.applyNeutral(neutralColor.color)
            } catch {
                issues.append(Issue(text: "Couldn't change the wallpaper: \(error.localizedDescription)"))
            }

        case .desktopCover:
            snap.markApplied(step)
            persist(snap)
            DesktopCover.shared.show(style: coverStyle == .wallpaper ? .wallpaper : .color(neutralColor.color))

        case .hideApps:
            // Keep the app you were using (the one behind Display Buddy's menu) on screen.
            let keep = AppRules.shared.lastApp?.bundleID
            let front = keep.flatMap { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first }
            snap.frontmostApp = front.map { HiddenApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }
            let candidates = AppHiding.appsToHide(running: Self.runningApps(), ownPID: getpid(), keepBundleIDs: keep.map { [$0] } ?? [])
            snap.hiddenApps = candidates.map { HiddenApp(pid: $0.pid, bundleID: $0.bundleID) }
            snap.markApplied(step)
            persist(snap)
            for app in candidates { NSRunningApplication(processIdentifier: app.pid)?.hide() }
        }
    }

    private func applyFocus(to snap: inout PresentationSnapshot) async {
        guard let available = await FocusShortcuts.list() else {
            issues.append(Issue(text: "Couldn't reach the Shortcuts app, so Do Not Disturb wasn't turned on."))
            return
        }
        let missing = FocusStatus.missing(required: [focusOnShortcut, focusOffShortcut], available: available)
        guard missing.isEmpty, !focusOnShortcut.isEmpty, !focusOffShortcut.isEmpty else {
            let names = missing.isEmpty ? "the On and Off shortcuts" : missing.map { "“\($0)”" }.joined(separator: " and ")
            issues.append(Issue(text: "Do Not Disturb needs \(names) in the Shortcuts app. See Presence settings for the steps.",
                                action: .openPresenceSettings))
            return
        }
        if !focusStatusShortcut.isEmpty, available.contains(focusStatusShortcut) {
            let status = await FocusShortcuts.run(shortcut: focusStatusShortcut, captureOutput: true)
            if status.succeeded, FocusStatus.isFocusOn(shortcutOutput: status.output) {
                // A Focus was already on: leave it, and don't turn it off afterwards.
                return
            }
        }
        snap.focusTurnedOn = true
        snap.markApplied(.focus)
        persist(snap)
        let result = await FocusShortcuts.run(shortcut: focusOnShortcut)
        if !result.succeeded {
            issues.append(Issue(text: "The “\(focusOnShortcut)” shortcut didn't finish\(result.error.isEmpty ? "" : ": \(result.error)")."))
        }
    }

    // MARK: Turn off / restore

    func turnOff() async {
        guard isOn, !isBusy, let snap = snapshot ?? loadSnapshot() else { return }
        isBusy = true
        issues = []
        ShareArea.shared.stopForPresentation()
        await restore(snap)
        isOn = false
        isBusy = false
    }

    /// At launch: a snapshot on disk means the app crashed or was force-quit
    /// while presentation mode was on (or an earlier restore didn't finish).
    func recoverIfNeeded() async {
        switch store.load() {
        case .none:
            return
        case .unreadable:
            issues.append(Issue(text: "The saved presentation settings couldn't be read, so they couldn't be restored automatically."))
        case .snapshot(let snap):
            isBusy = true
            await restore(snap)
            isBusy = false
            if issues.isEmpty { notice = "Restored the settings presentation mode had changed before Display Buddy last quit." }
        }
    }

    func retryRestore() {
        Task {
            issues = []
            await recoverIfNeeded()
        }
    }

    /// Undoes every applied step, newest first. Steps that can't be undone now
    /// stay in the snapshot on disk and are retried later.
    private func restore(_ original: PresentationSnapshot) async {
        var snap = original
        for step in snap.restoreOrder {
            if await undo(step, in: &snap) { snap.markRestored(step) }
        }
        snapshot = nil
        if snap.isFullyRestored {
            do {
                try store.remove()
            } catch {
                issues.append(Issue(text: "Couldn't remove the saved presentation settings: \(error.localizedDescription)"))
            }
        } else {
            persist(snap)
            let left = snap.restoreOrder.map(\.title).joined(separator: ", ")
            issues.append(Issue(text: "Couldn't put back: \(left). Display Buddy will try again at next launch.", action: .retryRestore))
        }
    }

    private func undo(_ step: PresentationStep, in snap: inout PresentationSnapshot) async -> Bool {
        switch step {
        case .keepAwake:
            KeepAwake.shared.release(.presentation)
            return true

        case .focus:
            guard snap.focusTurnedOn else { return true }
            let result = await FocusShortcuts.run(shortcut: focusOffShortcut)
            if result.succeeded { snap.focusTurnedOn = false }
            return result.succeeded

        case .dockAndMenuBar:
            guard let before = snap.dockMenuBar else { return true }
            if case .failure(let failure) = await DockMenuBar.set(dock: before.dockAutohide, menuBar: before.menuBarAutohide) {
                report(failure, step: step)
                return false
            }
            return true

        case .alertVolume:
            guard let volume = snap.alertVolume else { return true }
            return await AlertVolume.set(volume)

        case .displayPreset:
            guard let before = snap.display else { return true }
            let m = DisplayManager.shared
            m.colorMode = ColorMode(rawValue: before.colorMode) ?? m.colorMode
            m.manualKelvin = before.manualKelvin
            m.brightness = before.brightness
            m.adaptiveBrightness = before.adaptive
            return true

        case .wallpaper:
            snap.wallpapers = Wallpaper.restore(snap.wallpapers)
            return snap.wallpapers.isEmpty

        case .desktopCover:
            DesktopCover.shared.hide()
            return true

        case .hideApps:
            for app in AppHiding.appsToUnhide(hidden: snap.hiddenApps, running: Self.runningApps()) {
                NSRunningApplication(processIdentifier: app.pid)?.unhide()
            }
            if let front = snap.frontmostApp, let app = NSRunningApplication(processIdentifier: front.pid),
               front.bundleID == nil || app.bundleIdentifier == front.bundleID {
                app.activate()
            }
            return true
        }
    }

    // MARK: Quit

    /// Restores everything before the app quits. Calls `done` when finished,
    /// or after 15 seconds at most (the snapshot on disk covers the rest).
    func prepareToQuit(_ done: @escaping () -> Void) {
        guard isOn else { done(); return }
        var finished = false
        let finish = { if !finished { finished = true; done() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish() }
        Task {
            while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            await turnOff()
            finish()
        }
    }

    // MARK: Helpers

    @discardableResult
    private func persist(_ snap: PresentationSnapshot) -> Bool {
        do {
            try store.save(snap)
            return true
        } catch {
            issues.append(Issue(text: "Couldn't save the current settings, so presentation mode didn't change anything: \(error.localizedDescription)"))
            return false
        }
    }

    private func loadSnapshot() -> PresentationSnapshot? {
        if case .snapshot(let s) = store.load() { return s }
        return nil
    }

    private func report(_ failure: AppleScript.Failure, step: PresentationStep) {
        let action: Issue.Action? = failure.needsPermission ? .openAutomationSettings : nil
        issues.append(Issue(text: "\(step.title): \(failure.message)", action: action))
    }

    private static func runningApps() -> [AppHiding.RunningApp] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map {
            AppHiding.RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                                 isRegular: $0.activationPolicy == .regular, isHidden: $0.isHidden)
        }
    }
}
