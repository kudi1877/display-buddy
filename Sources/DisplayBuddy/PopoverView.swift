import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @ObservedObject var manager = DisplayManager.shared
    @ObservedObject var prefs = AppPrefs.shared
    @State private var keysActive = KeyboardTap.shared.isTrusted
    @State private var showMonitors = true
    @State private var hotkeysOn = Hotkeys.shared.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            masterCard
            presetsRow
            if !manager.monitors.isEmpty { monitorsCard }
            colorCard
            footer
        }
        .padding(16)
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
                Text(manager.brightness < 0 ? "Sub-zero \(Int(manager.brightness))" : "\(Int(manager.brightness))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(manager.brightness < 0 ? Color.indigo : Color.primary)
            }
            HStack(spacing: 8) {
                Image(systemName: manager.subZeroEnabled ? "moon.fill" : "sun.min").foregroundStyle(.secondary)
                Slider(value: $manager.brightness, in: manager.minBrightness ... 100)
                    .tint(manager.brightness < 0 ? .indigo : .orange)
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
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
                        Section {
                            Button("Turn screen off") { monitor.setPower(on: false) }
                            Button("Wake screen") { monitor.setPower(on: true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Input and power")
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
