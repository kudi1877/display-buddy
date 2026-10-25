import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var manager = DisplayManager.shared
    @ObservedObject var prefs = AppPrefs.shared
    @ObservedObject var appRules = AppRules.shared
    @ObservedObject var presence = Presence.shared
    @State private var keysActive = KeyboardTap.shared.isTrusted
    @State private var showMonitors = true
    @State private var showApps = false
    @State private var hotkeysOn = Hotkeys.shared.isEnabled
    @ObservedObject private var layout = PopoverLayout.shared
    @State private var cardsHeight: CGFloat = 600
    @State private var footerHeight: CGFloat = 120
    @State private var topHeight: CGFloat = 80
    @AppStorage("popover.tab") private var tab: PopoverTab = .brightness

    enum PopoverTab: String, CaseIterable, Identifiable {
        case brightness, keepAwake, presentation
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brightness: return "Brightness"
            case .keepAwake: return "Keep Awake"
            case .presentation: return "Presentation"
            }
        }
    }

    /// Without the Keep Awake & Presentation module there is only one section.
    private var shownTab: PopoverTab { presence.enabled ? tab : .brightness }

    /// Header and tabs on top, the selected section in the middle (scrolls when
    /// it doesn't fit the screen), and the footer pinned at the bottom.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if presence.enabled {
                    Picker("", selection: $tab) {
                        ForEach(PopoverTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 12)
            .background(HeightReader(height: $topHeight))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    switch shownTab {
                    case .brightness:
                        masterCard
                        presetsRow
                        if !manager.monitors.isEmpty { monitorsCard }
                        appsCard
                        colorCard
                    case .keepAwake:
                        KeepAwakeTab()
                    case .presentation:
                        PresentationTab()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .background(HeightReader(height: $cardsHeight))
            }
            .frame(height: min(cardsHeight, max(layout.maxHeight - footerHeight - topHeight, 200)))
            footer
                .padding([.horizontal, .bottom], 16)
                .background(HeightReader(height: $footerHeight))
        }
        .frame(width: 340)
        .onAppear { keysActive = KeyboardTap.shared.isTrusted }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Display Buddy").font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            KelvinBadge(kelvin: manager.currentKelvin)
        }
    }

    private var subtitle: String {
        let n = manager.monitors.count
        return n == 0 ? "No external monitors found" : manager.profileName
    }

    private var masterCard: some View {
        Card {
            HStack {
                Label("Brightness", systemImage: "sun.max.fill").labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(shown < 0 ? "Sub-zero \(Int(shown))" : "\(Int(shown))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(shown < 0 ? Color.indigo : Color.primary)
            }
            HStack(spacing: 8) {
                Image(systemName: manager.subZeroEnabled ? "moon.fill" : "sun.min").foregroundStyle(.secondary)
                Slider(value: brightnessBinding, in: manager.minBrightness ... 100)
                    .tint(shown < 0 ? .indigo : .orange)
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
            }
            if let rule = appRules.activeRule {
                Label("Setting \(rule.name)'s own brightness (per-app). Other apps: \(Int(manager.brightness))%", systemImage: "app.badge")
                    .font(.system(size: 10)).foregroundStyle(.teal)
            }
            Toggle(isOn: $manager.adaptiveBrightness) {
                Text("Follow the sun").font(.system(size: 12))
                Text(manager.adaptiveBrightness
                    ? "Day \(Int(manager.dayBrightness)) · Night \(Int(manager.nightBrightness)). Learns from your changes."
                    : "Brighter by day, dimmer at night")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
            Toggle(isOn: $manager.subZeroEnabled) {
                Text("Sub-zero dimming").font(.system(size: 12))
                Text("Go darker than the monitor allows").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch).controlSize(.mini)
        }
    }

    /// What the monitors show now: the per-app brightness while an app with a rule is in front.
    private var shown: Double { appRules.activeRule?.brightness ?? manager.brightness }

    /// While an app with its own brightness is in front, the slider adjusts that
    /// app's brightness (like the brightness keys do); otherwise the shared one.
    /// Before, it moved the hidden shared value, so the screens didn't change.
    private var brightnessBinding: Binding<Double> {
        Binding(get: { shown }, set: { value in
            if let rule = appRules.activeRule {
                appRules.setBrightness(value, for: rule.bundleID)
            } else {
                manager.brightness = value
            }
        })
    }

    private var presetsRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(Preset.allCases.enumerated()), id: \.element) { index, preset in
                Button { manager.apply(preset: preset) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: preset.icon).font(.system(size: 15))
                        Text(preset.title).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(preset.title) preset (⌃⌥\(index + 1))")
            }
        }
    }

    private var monitorsCard: some View {
        Card {
            DisclosureGroup(isExpanded: $showMonitors) {
                VStack(spacing: 10) {
                    ForEach(manager.monitors) { m in MonitorRow(monitor: m) }
                    HStack {
                        Text("Contrast").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $manager.contrast, in: 0 ... 100).controlSize(.small)
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Monitors", systemImage: "display.2")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var appsCard: some View {
        Card {
            DisclosureGroup(isExpanded: $showApps) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $appRules.enabled) {
                        Text("Per-app brightness").font(.system(size: 12))
                        Text("Switches brightness when these apps are in front").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    ForEach(appRules.rules) { rule in AppRuleRow(rule: rule) }
                    HStack {
                        if let last = appRules.lastApp, !appRules.hasRule(for: last.bundleID) {
                            Button("Add \(last.name)") { appRules.add(bundleID: last.bundleID, name: last.name) }
                                .help("Uses the brightness on screen now; adjust it below")
                        }
                        Button("Choose app…") { appRules.addFromFinder() }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 6)
            } label: {
                Label(appRules.rules.isEmpty ? "Apps" : "Apps (\(appRules.rules.count))", systemImage: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var colorCard: some View {
        Card {
            HStack {
                Label("Colour temperature", systemImage: "thermometer.sun.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $manager.colorMode) {
                    ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            switch manager.colorMode {
            case .manual:
                KelvinSlider(value: $manager.manualKelvin)
            case .auto:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Night warmth").font(.system(size: 11)).foregroundStyle(.secondary)
                    KelvinSlider(value: $manager.nightKelvin)
                    if let sun = manager.sunTimes {
                        Text("Sunrise \(sun.sunrise.formatted(date: .omitted, time: .shortened)) · Sunset \(sun.sunset.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            case .off:
                EmptyView()
            }
            if manager.colorMode != .off {
                Toggle("Warmer when dimmed", isOn: $manager.warmerWhenDim)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !keysActive {
                Button {
                    KeyboardTap.shared.requestPermission()
                    AppDelegate.shared?.waitForAccessibility()
                } label: {
                    Label("Turn on keyboard brightness keys", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
            Toggle(isOn: $hotkeysOn) {
                Text("Keyboard shortcuts").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("⌃⌥↑ ↓ brightness · ⌃⌥← → warmer / cooler · ⌃⌥1–4 presets")
            .onChange(of: hotkeysOn) { Hotkeys.shared.isEnabled = $0 }
            if hotkeysOn {
                Text("⌃⌥↑↓ brightness · ⌃⌥←→ warmth · ⌃⌥1–4 presets")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Toggle(isOn: $presence.enabled) {
                Text("Keep Awake & Presentation mode").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .help("Keep the Mac awake, and make the screens presentation-safe in one click")
            HStack {
                Toggle("Dock icon", isOn: $prefs.showInDock).toggleStyle(.checkbox)
                Toggle("Open at login", isOn: $prefs.launchAtLogin).toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            .font(.system(size: 11))
        }
    }
}

struct MonitorRow: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var manager = DisplayManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "display").foregroundStyle(.secondary)
                Text(monitor.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !monitor.hasHardwareControl {
                    Text("software only").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .help("This monitor doesn't accept hardware commands (common with DisplayLink docks), so it is dimmed in software.")
                }
                Spacer()
                if monitor.hasHardwareControl {
                    Menu {
                        Section("Switch input") {
                            ForEach(MonitorInput.allCases) { input in
                                Button(input.label) { monitor.setInput(input) }
                            }
                        }
                        Menu("Resolution") {
                            let current = DisplayLayout.current(for: monitor.id)
                            ForEach(DisplayLayout.resolutions(for: monitor.id)) { r in
                                Button {
                                    DisplayLayout.set(r, on: monitor.id)
                                } label: {
                                    let title = r.hiDPI ? "\(r.label)  (HiDPI)" : r.label
                                    if r == current { Label(title, systemImage: "checkmark") } else { Text(title) }
                                }
                            }
                        }
                        if DisplayLayout.canRotate(monitor.id) {
                            Menu("Rotation") {
                                let current = DisplayLayout.rotation(of: monitor.id)
                                ForEach(DisplayLayout.rotations, id: \.self) { deg in
                                    Button {
                                        DisplayLayout.rotate(monitor.id, to: deg)
                                    } label: {
                                        let title = deg == 0 ? "Standard (landscape)" : "\(deg)°" + (deg == 90 || deg == 270 ? " (portrait)" : "")
                                        if deg == current { Label(title, systemImage: "checkmark") } else { Text(title) }
                                    }
                                }
                            }
                        }
                        Section {
                            Button("Turn screen off") { monitor.setPower(on: false) }
                            Button("Wake screen") { monitor.setPower(on: true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Resolution, rotation, input and power")
                }
                Toggle(isOn: $monitor.linked) { Image(systemName: monitor.linked ? "link" : "link.badge.plus") }
                    .toggleStyle(.button).controlSize(.small)
                    .help(monitor.linked ? "Follows the main slider" : "Adjusted on its own")
            }
            if monitor.linked {
                HStack {
                    Text("Match").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                    Slider(value: $monitor.offset, in: -40 ... 40).controlSize(.mini)
                    Text(monitor.offset == 0 ? "±0" : (monitor.offset > 0 ? "+" : "") + "\(Int(monitor.offset))")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                }
            } else {
                HStack {
                    Text("Own").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                    Slider(value: $monitor.ownBrightness, in: manager.minBrightness ... 100).controlSize(.mini)
                    Text("\(Int(monitor.ownBrightness))").font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 28)
                }
            }
        }
    }
}

struct AppRuleRow: View {
    let rule: AppRules.Rule
    @ObservedObject var rules = AppRules.shared
    @ObservedObject var manager = DisplayManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if let icon = AppRules.icon(for: rule.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(rule.name).font(.system(size: 11)).lineLimit(1).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { rule.brightness }, set: { rules.setBrightness($0, for: rule.bundleID) }),
                   in: manager.minBrightness ... 100).controlSize(.mini)
            Text("\(Int(rule.brightness))").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
            Button { rules.remove(rule) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove")
        }
    }
}

struct KelvinSlider: View {
    @Binding var value: Double
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill").foregroundStyle(.orange)
            Slider(value: $value, in: 1900 ... 6500, step: 100).controlSize(.small)
            Text("\(Int(value))K").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 46)
        }
    }
}

struct KelvinBadge: View {
    let kelvin: Double
    var body: some View {
        let c = Gamma.whitePoint(kelvin: kelvin)
        HStack(spacing: 4) {
            Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 0.5))
            Text("\(Int(kelvin.rounded()))K").font(.system(size: 10, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

/// Reports a view's height, so the popover can size its scroll area to the content.
struct HeightReader: View {
    @Binding var height: CGFloat
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { height = proxy.size.height }
                .onChange(of: proxy.size.height) { height = $0 }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// App-level preferences: Dock icon and open-at-login.
final class AppPrefs: ObservableObject {
    static let shared = AppPrefs()

    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockPolicy()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Display Buddy: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        UserDefaults.standard.register(defaults: ["showInDock": true])
        showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func applyDockPolicy() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }
}
