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
        didSet { defaults.set(brightness, forKey: "brightness"); applyAll() }
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
        didSet { defaults.set(colorMode.rawValue, forKey: "colorMode"); updateKelvin() }
    }
    @Published var manualKelvin: Double {
        didSet { defaults.set(manualKelvin, forKey: "manualKelvin"); updateKelvin() }
    }
    @Published var nightKelvin: Double {
        didSet { defaults.set(nightKelvin, forKey: "nightKelvin"); updateKelvin() }
    }
    @Published var warmerWhenDim: Bool {
        didSet { defaults.set(warmerWhenDim, forKey: "warmerWhenDim"); updateKelvin() }
    }
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

    var minBrightness: Double { subZeroEnabled ? -100 : 0 }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "brightness": 60.0, "subZero": true, "contrast": 70.0, "colorMode": ColorMode.auto.rawValue,
            "manualKelvin": 5000.0, "nightKelvin": 3400.0, "warmerWhenDim": true,
        ])
        brightness = defaults.double(forKey: "brightness")
        subZeroEnabled = defaults.bool(forKey: "subZero")
        contrast = defaults.double(forKey: "contrast")
        colorMode = ColorMode(rawValue: defaults.string(forKey: "colorMode") ?? "") ?? .auto
        manualKelvin = defaults.double(forKey: "manualKelvin")
        nightKelvin = defaults.double(forKey: "nightKelvin")
        warmerWhenDim = defaults.bool(forKey: "warmerWhenDim")
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
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.updateKelvin() })
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.applyAll() }
    }

    // MARK: Brightness

    func effectiveBrightness(_ m: Monitor) -> Double {
        let value = m.linked ? brightness + m.offset : m.ownBrightness
        return min(max(value, minBrightness), 100)
    }

    func step(by delta: Double) {
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
        if colorMode != .off, warmerWhenDim, brightness < 30 {
            // Gently warm the picture further as you dim, like Lunar Pro.
            let t = (30 - max(brightness, -100)) / 130
            kelvin = target - (target - min(nightKelvin, target)) * t * 0.5
        }
        currentKelvin = kelvin
        applyGammaAll()
    }

    private func sunKelvin(at date: Date) -> Double {
        let loc = location
        guard let times = Solar.sunriseSunset(date: date, latitude: loc.latitude, longitude: loc.longitude) else {
            return 6500
        }
        sunTimes = times
        let fade: TimeInterval = 60 * 60 // one-hour smooth transition
        let t = date.timeIntervalSince1970
        let rise = times.sunrise.timeIntervalSince1970, set = times.sunset.timeIntervalSince1970
        let day = 6500.0, night = nightKelvin
        if t < rise - fade / 2 || t > set + fade / 2 { return night }
        if t > rise + fade / 2, t < set - fade / 2 { return day }
        if t <= rise + fade / 2 {
            let p = (t - (rise - fade / 2)) / fade
            return night + (day - night) * p
        }
        let p = (t - (set - fade / 2)) / fade
        return day + (night - day) * p
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
