import PresenceCore
import SwiftUI

// MARK: - Keep Awake tab

/// The Keep Awake tab of the popover: on/off, duration, mode, app triggers and options.
struct KeepAwakeTab: View {
    @ObservedObject var keepAwake = KeepAwake.shared
    @ObservedObject var triggers = AppTriggers.shared
    @ObservedObject var power = PowerWatcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: keepAwake.state.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 18)).foregroundStyle(keepAwake.state.isActive ? Color.orange : Color.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Awake").font(.system(size: 13, weight: .semibold))
                        statusText
                    }
                    Spacer()
                    Toggle("", isOn: manualBinding).toggleStyle(.switch).labelsHidden().help("⌃⌥K")
                }
                HStack {
                    Text("Duration").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Menu(keepAwake.lastDuration.label) {
                        ForEach(KeepAwakeDuration.presets, id: \.self) { d in Button(d.label) { keepAwake.startManual(d) } }
                        Divider()
                        Button("Custom: \(keepAwake.customDuration.label)") { keepAwake.startManual(keepAwake.customDuration) }
                        Button(keepAwake.untilDuration.label) { keepAwake.startManual(keepAwake.untilDuration) }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11))
                    .help("Choosing a duration turns Keep Awake on")
                }
                Picker("", selection: $keepAwake.mode) {
                    Text("Keep display on").tag(KeepAwakeMode.display)
                    Text("Display may sleep").tag(KeepAwakeMode.system)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                Text(keepAwake.mode == .display ? "Screens and Mac stay awake." : "Screens can turn off; the Mac keeps running (downloads, calls, builds).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Card {
                Label("Stay awake while these apps run", systemImage: "app.badge.checkmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(triggers.apps) { app in
                    HStack(spacing: 6) {
                        if let icon = AppRules.icon(for: app.bundleID) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                        Text(app.name).font(.system(size: 11)).lineLimit(1)
                        if triggers.isRunning(app.bundleID) {
                            Text("running").font(.system(size: 9, weight: .semibold)).foregroundStyle(.teal)
                        }
                        Spacer()
                        Button { triggers.remove(app) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
                    }
                }
                Button("Choose app…") { triggers.addFromFinder() }.controlSize(.small)
            }

            Card {
                Label("Options", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Stepper(value: $keepAwake.customMinutes, in: KeepAwakeDuration.customMinutesRange, step: 5) {
                    Text("Custom duration: \(KeepAwakeDuration.describe(minutes: keepAwake.customMinutes))").font(.system(size: 11))
                }
                .controlSize(.small)
                HStack {
                    Text("“Until” time").font(.system(size: 11))
                    Spacer()
                    DatePicker("", selection: untilBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field).controlSize(.small)
                }
                Toggle("Notify me when a timed session ends", isOn: $keepAwake.notifyWhenEnded)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                if power.hasBattery {
                    Toggle("Turn off when the battery is low", isOn: $power.cutoffEnabled)
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    if power.cutoffEnabled {
                        Stepper(value: $power.threshold, in: BatteryCutoff.thresholdRange, step: 5) {
                            Text("Below \(power.threshold)% (not during presentations)").font(.system(size: 11))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var statusText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(status(at: context.date)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func status(at date: Date) -> String {
        if keepAwake.isManualOn {
            guard let left = keepAwake.remaining(now: date) else { return "On until you turn it off" }
            return "On · \(RemainingTime.format(left)) left"
        }
        if let reason = keepAwake.reasonText { return "On while \(reason) is running" }
        return "Off"
    }

    private var manualBinding: Binding<Bool> {
        Binding(get: { keepAwake.isManualOn }, set: { $0 ? keepAwake.startManual(keepAwake.lastDuration) : keepAwake.stopManual() })
    }

    private var untilBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: keepAwake.untilMinutes / 60, minute: keepAwake.untilMinutes % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            keepAwake.untilMinutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
}

// MARK: - Presentation tab

extension PresentationStep {
    /// One-line explanation shown under each option.
    var detail: String {
        switch self {
        case .keepAwake: return "Screens stay on for the whole presentation."
        case .wallpaper: return "Swaps every screen's wallpaper for a plain neutral colour."
        case .desktopCover: return "Covers the files and icons on your desktop."
        case .displayPreset: return "Monitors at 100% with no warm tint, so colours look right."
        case .alertVolume: return "Mutes alert beeps; music and video volume are untouched."
        case .hideApps: return "Hides other apps; keeps the one you were using in front."
        case .focus: return "Turns on Do Not Disturb (needs two Shortcuts)."
        case .dockAndMenuBar: return "Auto-hides the Dock and the menu bar."
        }
    }
}

/// The Presentation tab: one big button, problems, and what each option does.
struct PresentationTab: View {
    @ObservedObject var presentation = PresentationMode.shared
    @ObservedObject var share = ShareArea.shared
    @State private var shortcutsFound: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            presentationCard
            shareCard
            optionsCard
        }
        .task { await checkShortcuts() }
    }

    /// Share a landscape part of a portrait screen through any call app's "Share window".
    private var shareCard: some View {
        Card {
            HStack(spacing: 10) {
                Image(systemName: share.isRunning ? "rectangle.dashed.badge.record" : "rectangle.dashed")
                    .font(.system(size: 18)).foregroundStyle(share.isRunning ? Color.orange : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share an area").font(.system(size: 13, weight: .semibold))
                    Text(share.isRunning ? "Drag the orange frame to choose what people see" : "A landscape part of a vertical screen")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(share.isRunning ? "Stop" : "Share area") { share.toggle() }
                    .controlSize(.small)
            }
            if share.isRunning {
                Text("In Teams, Zoom, Slack, Discord, Meet or Whereby choose Share → Window → “\(ShareArea.mirrorTitle)”.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Shape", selection: $share.aspect) {
                ForEach(ShareArea.Aspect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).controlSize(.small).font(.system(size: 11))
            Toggle("Show the mouse pointer", isOn: $share.showsCursor)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            Toggle("Start with presentation mode", isOn: $share.startWithPresentation)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            if let problem = share.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Label(problem.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if problem == .needsPermission {
                        Button("Open Screen Recording settings") { ShareArea.openScreenRecordingSettings() }.controlSize(.mini)
                    }
                }
            }
        }
    }

    private var presentationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: presentation.isOn ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 18)).foregroundStyle(presentation.isOn ? Color.accentColor : Color.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Presentation mode").font(.system(size: 13, weight: .semibold))
                        Text(presentation.isOn ? "On · turning it off puts everything back" : "Off")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if presentation.isBusy { ProgressView().controlSize(.small) }
                }
                Button { presentation.toggle() } label: {
                    Text(presentation.isOn ? "Turn off presentation mode" : "Turn on presentation mode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .tint(presentation.isOn ? .gray : .accentColor)
                .disabled(presentation.isBusy)
                .help("⌃⌥P")
                ForEach(presentation.issues) { issue in IssueRow(issue: issue) }
                if let notice = presentation.notice {
                    HStack(alignment: .top) {
                        Label(notice, systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { presentation.dismissNotice() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var optionsCard: some View {
            Card {
                Label("When it turns on", systemImage: "checklist")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(PresentationStep.allCases) { step in
                    Toggle(isOn: stepBinding(step)) {
                        Text(step.title).font(.system(size: 12))
                        Text(step.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    if step == .focus, presentation.enabledSteps.contains(.focus) { focusStatus }
                }
                if presentation.enabledSteps.contains(.desktopCover) || presentation.enabledSteps.contains(.wallpaper) {
                    Divider()
                    if presentation.enabledSteps.contains(.desktopCover) {
                        Picker("Desktop cover shows", selection: $presentation.coverStyle) {
                            ForEach(PresentationMode.CoverStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .font(.system(size: 11)).controlSize(.small)
                    }
                    Picker("Neutral colour", selection: $presentation.neutralColor) {
                        ForEach(NeutralColor.allCases) { Text($0.title).tag($0) }
                    }
                    .font(.system(size: 11)).controlSize(.small)
                }
                if presentation.isOn {
                    Text("Changes apply the next time you turn presentation mode on.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
    }

    private var focusStatus: some View {
        HStack(spacing: 6) {
            switch shortcutsFound {
            case .some(true):
                Label("Shortcuts found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .some(false):
                Label("Shortcuts not set up yet", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case nil:
                Text("Checking Shortcuts…").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Set up…") { FocusSetupWindow.shared.show() }.buttonStyle(.borderless)
        }
        .font(.system(size: 10))
        .padding(.leading, 4)
    }

    private func stepBinding(_ step: PresentationStep) -> Binding<Bool> {
        Binding(get: { presentation.enabledSteps.contains(step) }, set: { on in
            if on { presentation.enabledSteps.insert(step) } else { presentation.enabledSteps.remove(step) }
        })
    }

    private func checkShortcuts() async {
        guard let available = await FocusShortcuts.list() else { shortcutsFound = false; return }
        let p = presentation
        shortcutsFound = !p.focusOnShortcut.isEmpty && !p.focusOffShortcut.isEmpty
            && FocusStatus.missing(required: [p.focusOnShortcut, p.focusOffShortcut], available: available).isEmpty
    }
}

struct IssueRow: View {
    let issue: PresentationMode.Issue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(issue.text, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            switch issue.action {
            case .openAutomationSettings:
                Button("Open Automation settings") { AppleScript.openAutomationSettings() }.controlSize(.mini)
            case .openPresenceSettings:
                Button("Show setup steps") { FocusSetupWindow.shared.show() }.controlSize(.mini)
            case .retryRestore:
                Button("Try again now") { PresentationMode.shared.retryRestore() }.controlSize(.mini)
            case nil:
                EmptyView()
            }
        }
    }
}

// MARK: - Do Not Disturb setup window

@MainActor
final class FocusSetupWindow {
    static let shared = FocusSetupWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Do Not Disturb for presentations"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: FocusSetupView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct FocusSetupView: View {
    @ObservedObject var presentation = PresentationMode.shared
    @State private var shortcutCheck: String?
    @State private var shortcutsOK = false

    var body: some View {
        Form {
            Section("Shortcut names") {
                TextField("“On” shortcut", text: $presentation.focusOnShortcut)
                TextField("“Off” shortcut", text: $presentation.focusOffShortcut)
                TextField("Status shortcut (optional)", text: $presentation.focusStatusShortcut)
                HStack {
                    Button("Check shortcuts") { Task { await checkShortcuts() } }
                    if let shortcutCheck {
                        Label(shortcutCheck, systemImage: shortcutsOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(shortcutsOK ? .green : .orange).font(.caption)
                    }
                }
            }
            Section("How to set it up") {
                FocusSetupSteps(on: presentation.focusOnShortcut, off: presentation.focusOffShortcut)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 400)
        .task { await checkShortcuts() }
    }

    private func checkShortcuts() async {
        guard let available = await FocusShortcuts.list() else {
            shortcutsOK = false
            shortcutCheck = "Couldn't run the Shortcuts tool"
            return
        }
        let p = presentation
        var missing = FocusStatus.missing(required: [p.focusOnShortcut, p.focusOffShortcut], available: available)
        if p.focusOnShortcut.isEmpty || p.focusOffShortcut.isEmpty { missing.append("an On and an Off shortcut name") }
        let statusMissing = !p.focusStatusShortcut.isEmpty && !available.contains(p.focusStatusShortcut)
        shortcutsOK = missing.isEmpty
        if !missing.isEmpty {
            shortcutCheck = "Missing: " + missing.joined(separator: ", ")
        } else if statusMissing {
            shortcutCheck = "On/Off found; status shortcut “\(p.focusStatusShortcut)” not found"
        } else {
            shortcutCheck = "Shortcuts found"
        }
    }
}

/// How to make the two Focus shortcuts.
struct FocusSetupSteps: View {
    let on: String
    let off: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS has no public way for apps to switch Focus, so Display Buddy runs two shortcuts:")
            Text("1. Open the Shortcuts app and click + to make a new shortcut.")
            Text("2. Add the “Set Focus” action, choose Do Not Disturb, set it to Turn On, and name the shortcut “\(on)”.")
            Text("3. Make a second shortcut with “Set Focus” → Do Not Disturb → Turn Off, named “\(off)”.")
            Text("4. Click Check shortcuts above. (Optional: a third shortcut with “Get Current Focus”, named in the Status field, lets Display Buddy leave a Focus you already had on.)")
            Button("Open Shortcuts") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app")) }
        }
        .font(.callout).foregroundStyle(.secondary)
    }
}
