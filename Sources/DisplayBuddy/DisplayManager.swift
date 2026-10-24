import AppKit
import Combine
import CoreGraphics
import Foundation

/// One external monitor.
final class Monitor: ObservableObject, Identifiable {
    let id: CGDirectDisplayID
    let name: String
    /// Stable key (vendor-model-serial) used to remember settings per monitor,
    /// so home and work monitors each keep their own tuning.
    let key: String
    let ddc: DDCService?
    var maxHardware: UInt16 = 100

    @Published var linked: Bool { didSet { save() } }
    /// Added to the shared brightness so different models look equally bright.
    @Published var offset: Double { didSet { save() } }
    /// Used when the monitor is not linked to the shared slider.
    @Published var ownBrightness: Double { didSet { save() } }

    private let writer: CoalescingWriter?

    init(id: CGDirectDisplayID, ddc: DDCService?, registryName: String?) {
        self.id = id
        self.ddc = ddc
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
        key = "\(vendor)-\(model)-\(serial)"
        let screenName = NSScreen.screens.first { $0.displayID == id }?.localizedName
        name = registryName ?? screenName ?? "Display \(id)"
        let stored = UserDefaults.standard.dictionary(forKey: "monitor.\(key)") ?? [:]
        linked = stored["linked"] as? Bool ?? true
        offset = stored["offset"] as? Double ?? 0
        ownBrightness = stored["own"] as? Double ?? 60
        writer = ddc.map { CoalescingWriter(ddc: $0) }
    }

    var hasHardwareControl: Bool { ddc != nil }

    func readMax() {
        guard let ddc else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let reading = ddc.read(.brightness) {
                DispatchQueue.main.async { self?.maxHardware = reading.max }
            }
        }
    }

    func setHardware(percent: Double) {
        let value = UInt16((min(max(percent, 0), 100) / 100 * Double(maxHardware)).rounded())
        writer?.set(.brightness, value)
    }

    func setDDC(_ code: VCP, percent: Double) {
        writer?.set(code, UInt16(min(max(percent, 0), 100).rounded()))
    }

    /// Switches the monitor to another input (cable). Sent directly so the
    /// same input can be chosen again after using the monitor's own buttons.
    func setInput(_ input: MonitorInput) {
        guard let ddc else { return }
        DispatchQueue.global(qos: .userInitiated).async { ddc.write(.inputSource, value: input.rawValue) }
    }

    /// Puts the screen to sleep (DDC power mode "standby"). Pressing the
    /// monitor's power button, or "Wake screen", turns it back on.
    func setPower(on: Bool) {
        guard let ddc else { return }
        DispatchQueue.global(qos: .userInitiated).async { ddc.write(.power, value: on ? 1 : 4) }
    }

    private func save() {
        UserDefaults.standard.set(["linked": linked, "offset": offset, "own": ownBrightness], forKey: "monitor.\(key)")
    }
}

/// DDC is slow (~50 ms per command). When a slider moves quickly we only send
/// the newest value, on a background queue, so the UI never stutters.
final class CoalescingWriter {
    private let ddc: DDCService
    private let queue = DispatchQueue(label: "ddc.writer")
    private var pending: [VCP: UInt16] = [:]
    private var lastSent: [VCP: UInt16] = [:]
    private var busy = false
    private let lock = NSLock()

    init(ddc: DDCService) { self.ddc = ddc }

    func set(_ code: VCP, _ value: UInt16) {
        lock.lock()
        pending[code] = value
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending.first else { busy = false; lock.unlock(); return }
            let code = next.key, value = next.value
            pending[code] = nil
            lock.unlock()
            if lastSent[code] != value {
                ddc.write(code, value: value)
                lastSent[code] = value
            }
        }
    }
}

enum MonitorInput: UInt16, CaseIterable, Identifiable {
    case displayPort1 = 0x0F, displayPort2 = 0x10, hdmi1 = 0x11, hdmi2 = 0x12, usbC = 0x1B
    var id: UInt16 { rawValue }
    var label: String {
        switch self {
        case .displayPort1: return "DisplayPort 1"
        case .displayPort2: return "DisplayPort 2"
        case .hdmi1: return "HDMI 1"
        case .hdmi2: return "HDMI 2"
        case .usbC: return "USB-C"
        }
    }
}

enum Preset: String, CaseIterable, Identifiable {
    case day, reading, movie, night
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .day: return "sun.max.fill"
        case .reading: return "book.fill"
        case .movie: return "film.fill"
        case .night: return "moon.stars.fill"
        }
    }
    var brightness: Double {
        switch self {
        case .day: return 80
        case .reading: return 55
        case .movie: return 35
        case .night: return -35
        }
    }
    /// nil means "follow the sun".
    var kelvin: Double? {
        switch self {
        case .day: return nil
        case .reading: return 5200
        case .movie: return 6200
        case .night: return 2700
        }
    }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case off, manual, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .manual: return "Manual"
        case .auto: return "Sun"
        }
    }
}

final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published private(set) var monitors: [Monitor] = []

    /// Shared brightness, -100...100. Below 0 is "sub-zero" software dimming.
    @Published var brightness: Double {
        didSet {
            defaults.set(brightness, forKey: "brightness")
            if adaptiveBrightness, !applyingAutomatic, !applyingProfile { learnFromManual() }
            saveProfile()
            applyAll()
        }
    }
    @Published var subZeroEnabled: Bool {
        didSet {
            defaults.set(subZeroEnabled, forKey: "subZero")
            if !subZeroEnabled, brightness < 0 { brightness = 0 } else { applyAll() }
        }
    }
    @Published var contrast: Double {
        didSet { defaults.set(contrast, forKey: "contrast"); monitors.forEach { $0.setDDC(.contrast, percent: contrast) } }
    }
    @Published var colorMode: ColorMode {
        didSet { defaults.set(colorMode.rawValue, forKey: "colorMode"); saveProfile(); updateKelvin() }
    }
    @Published var manualKelvin: Double {
        didSet { defaults.set(manualKelvin, forKey: "manualKelvin"); saveProfile(); updateKelvin() }
    }
    @Published var nightKelvin: Double {
        didSet { defaults.set(nightKelvin, forKey: "nightKelvin"); updateKelvin() }
    }
    @Published var warmerWhenDim: Bool {
        didSet { defaults.set(warmerWhenDim, forKey: "warmerWhenDim"); updateKelvin() }
    }
    /// Brightness follows the sun: bright by day, dim at night.
    @Published var adaptiveBrightness: Bool {
        didSet { defaults.set(adaptiveBrightness, forKey: "adaptive"); saveProfile(); updateAdaptive() }
    }
    @Published var dayBrightness: Double {
        didSet { defaults.set(dayBrightness, forKey: "dayBrightness"); saveProfile() }
    }
    @Published var nightBrightness: Double {
        didSet { defaults.set(nightBrightness, forKey: "nightBrightness"); saveProfile() }
    }
    /// Per-app brightness for the app in front (see AppRules); replaces the
    /// shared brightness while set, without changing it.
    @Published var appOverride: Double? {
        didSet { applyAll() }
    }
    /// Brightness the linked monitors are showing right now.
    var shownBrightness: Double { appOverride ?? brightness }
    /// Name of the current monitor setup, e.g. "3 × DELL P3221D".
    @Published private(set) var profileName: String = ""
    @Published private(set) var currentKelvin: Double = 6500
    @Published var sunTimes: (sunrise: Date, sunset: Date)? = nil

    var location: (latitude: Double, longitude: Double) {
        didSet {
            defaults.set(location.latitude, forKey: "lat")
            defaults.set(location.longitude, forKey: "lon")
            updateKelvin()
        }
    }

    private let defaults = UserDefaults.standard
    private var observers: [NSObjectProtocol] = []
    private var timers: [Timer] = []
    private var monitorBag: [AnyCancellable] = []
    private var profileKey: String?
    private var applyingProfile = false
    private var applyingAutomatic = false

    var minBrightness: Double { subZeroEnabled ? -100 : 0 }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "brightness": 60.0, "subZero": true, "contrast": 70.0, "colorMode": ColorMode.auto.rawValue,
            "manualKelvin": 5000.0, "nightKelvin": 3400.0, "warmerWhenDim": true,
            "adaptive": false, "dayBrightness": 80.0, "nightBrightness": 30.0,
        ])
        brightness = defaults.double(forKey: "brightness")
        subZeroEnabled = defaults.bool(forKey: "subZero")
        contrast = defaults.double(forKey: "contrast")
        colorMode = ColorMode(rawValue: defaults.string(forKey: "colorMode") ?? "") ?? .auto
        manualKelvin = defaults.double(forKey: "manualKelvin")
        nightKelvin = defaults.double(forKey: "nightKelvin")
        warmerWhenDim = defaults.bool(forKey: "warmerWhenDim")
        adaptiveBrightness = defaults.bool(forKey: "adaptive")
        dayBrightness = defaults.double(forKey: "dayBrightness")
        nightBrightness = defaults.double(forKey: "nightBrightness")
        if defaults.object(forKey: "lat") != nil {
            location = (defaults.double(forKey: "lat"), defaults.double(forKey: "lon"))
        } else {
            location = Solar.guessedLocation()
        }
    }

    func start() {
        refreshMonitors()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // Monitors take a moment to become reachable after plugging in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.refreshMonitors() }
        })
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.refreshMonitors() }
            })
        }
        // Colour temperature follows the sun; check every minute.
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateAdaptive()
            self?.updateKelvin()
        })
        // Other apps or macOS can reset colour curves; re-assert them.
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.applyGammaAll() })
        updateKelvin()
    }

    func stop() {
        Gamma.restoreAll()
    }

    func refreshMonitors() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .sorted { CGDisplayBounds($0).minX < CGDisplayBounds($1).minX }
        let services = DDCDiscovery.externalServices()
        let matched = DDCDiscovery.match(displays: external, services: services)
        monitors = external.map { id in
            let reg = matched[id]
            return Monitor(id: id, ddc: reg.map { DDCService(service: $0.service) }, registryName: reg?.productName)
        }
        monitorBag = monitors.map { m in
            m.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.apply(m) }
            }
        }
        monitors.forEach { $0.readMax() }
        loadProfile()
        updateAdaptive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.applyAll() }
    }

    // MARK: Brightness

    func effectiveBrightness(_ m: Monitor) -> Double {
        let value = m.linked ? shownBrightness + m.offset : m.ownBrightness
        return min(max(value, minBrightness), 100)
    }

    func step(by delta: Double) {
        if AppRules.shared.stepActive(by: delta) { return }
        brightness = min(max(brightness + delta, minBrightness), 100)
    }

    func applyAll() {
        monitors.forEach(apply)
        if colorMode != .off, warmerWhenDim { updateKelvin() }
    }

    private func apply(_ m: Monitor) {
        let value = effectiveBrightness(m)
        if m.hasHardwareControl {
            m.setHardware(percent: max(value, 0))
        }
        applyGamma(m)
    }

    private func dimFactor(_ m: Monitor) -> Double {
        let value = effectiveBrightness(m)
        if m.hasHardwareControl {
            // Hardware handles 0...100; software takes over below zero.
            return value >= 0 ? 1 : max(0.05, 1 + value / 100 * 0.95)
        }
        // No hardware control (e.g. DisplayLink docks, TVs): software only.
        let normalized = (value + 100) / 200
        return max(0.05, 0.25 + 0.75 * normalized)
    }

    private func applyGamma(_ m: Monitor) {
        let dim = dimFactor(m)
        if Gamma.isNeutral(dim: dim, kelvin: currentKelvin) {
            Gamma.apply(to: m.id, dim: 1, kelvin: 6500)
        } else {
            Gamma.apply(to: m.id, dim: dim, kelvin: currentKelvin)
        }
    }

    private func applyGammaAll() { monitors.forEach(applyGamma) }

    // MARK: Colour temperature

    func updateKelvin() {
        let target: Double
        switch colorMode {
        case .off:
            target = 6500
        case .manual:
            target = manualKelvin
        case .auto:
            target = sunKelvin(at: Date())
        }
        var kelvin = target
        if colorMode != .off, warmerWhenDim, shownBrightness < 30 {
            // Gently warm the picture further as you dim, like Lunar Pro.
            let t = (30 - max(shownBrightness, -100)) / 130
            kelvin = target - (target - min(nightKelvin, target)) * t * 0.5
        }
        currentKelvin = kelvin
        applyGammaAll()
    }

    private func sunKelvin(at date: Date) -> Double {
        guard let p = sunProgress(at: date) else { return 6500 }
        return nightKelvin + (6500 - nightKelvin) * p
    }

    /// 0 = night, 1 = day, with a smooth one-hour change around sunrise and sunset.
    func sunProgress(at date: Date) -> Double? {
        let loc = location
        guard let times = Solar.sunriseSunset(date: date, latitude: loc.latitude, longitude: loc.longitude) else {
            return nil
        }
        if sunTimes?.sunrise != times.sunrise { sunTimes = times }
        let fade: TimeInterval = 60 * 60
        let t = date.timeIntervalSince1970
        let rise = times.sunrise.timeIntervalSince1970, set = times.sunset.timeIntervalSince1970
        if t < rise - fade / 2 || t > set + fade / 2 { return 0 }
        if t > rise + fade / 2, t < set - fade / 2 { return 1 }
        if t <= rise + fade / 2 { return (t - (rise - fade / 2)) / fade }
        return 1 - (t - (set - fade / 2)) / fade
    }

    // MARK: Adaptive brightness

    func updateAdaptive() {
        guard adaptiveBrightness, let p = sunProgress(at: Date()) else { return }
        let target = min(max(nightBrightness + (dayBrightness - nightBrightness) * p, minBrightness), 100)
        guard abs(target - brightness) >= 0.5 else { return }
        applyingAutomatic = true
        brightness = target
        applyingAutomatic = false
    }

    /// When you change brightness by hand, remember it as your preference for
    /// this time of day, so the automatic curve passes through your choice.
    private func learnFromManual() {
        guard let p = sunProgress(at: Date()) else { return }
        if p >= 0.5 {
            dayBrightness = min(max((brightness - nightBrightness * (1 - p)) / p, minBrightness), 100)
        } else {
            nightBrightness = min(max((brightness - dayBrightness * p) / (1 - p), minBrightness), 100)
        }
    }

    // MARK: Presets and shortcuts

    func apply(preset: Preset) {
        adaptiveBrightness = false
        brightness = min(max(preset.brightness, minBrightness), 100)
        if let k = preset.kelvin {
            manualKelvin = k
            colorMode = .manual
        } else {
            colorMode = .auto
        }
    }

    func shiftKelvin(by delta: Double) {
        if colorMode != .manual {
            manualKelvin = (currentKelvin / 100).rounded() * 100
            colorMode = .manual
        }
        manualKelvin = min(max(manualKelvin + delta, 1900), 6500)
    }

    // MARK: Profiles (home / work)

    /// Each set of connected monitors is its own profile, so the home and work
    /// desks keep their own brightness, colour and schedule.
    private func loadProfile() {
        guard !monitors.isEmpty else { profileKey = nil; profileName = ""; return }
        let key = monitors.map(\.key).sorted().joined(separator: "|")
        let names = Dictionary(grouping: monitors, by: \.name)
            .map { $0.value.count > 1 ? "\($0.value.count) × \($0.key)" : $0.key }
            .sorted()
        profileName = names.joined(separator: " + ")
        guard key != profileKey else { return }
        profileKey = key
        guard let p = defaults.dictionary(forKey: "profile.\(key)") else { saveProfile(); return }
        applyingProfile = true
        if let v = p["adaptive"] as? Bool { adaptiveBrightness = v }
        if let v = p["day"] as? Double { dayBrightness = v }
        if let v = p["night"] as? Double { nightBrightness = v }
        if let v = p["manualKelvin"] as? Double { manualKelvin = v }
        if let v = p["colorMode"] as? String, let mode = ColorMode(rawValue: v) { colorMode = mode }
        if let v = p["brightness"] as? Double { brightness = v }
        applyingProfile = false
    }

    private func saveProfile() {
        guard let key = profileKey, !applyingProfile else { return }
        defaults.set([
            "brightness": brightness, "adaptive": adaptiveBrightness, "day": dayBrightness,
            "night": nightBrightness, "manualKelvin": manualKelvin, "colorMode": colorMode.rawValue,
        ], forKey: "profile.\(key)")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
