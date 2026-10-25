import Foundation
import IOKit.ps
import PresenceCore

/// Optional battery cut-off: ends manual and app-triggered keep-awake when the
/// battery drops below the chosen level. Uses IOKit power-source notifications.
final class PowerWatcher: ObservableObject {
    static let shared = PowerWatcher()

    @Published var cutoffEnabled: Bool {
        didSet { UserDefaults.standard.set(cutoffEnabled, forKey: "presence.battery.enabled"); check() }
    }
    @Published var threshold: Int {
        didSet { UserDefaults.standard.set(threshold, forKey: "presence.battery.threshold"); check() }
    }
    /// False on Macs without a battery (the setting is hidden then).
    let hasBattery: Bool

    private var source: CFRunLoopSource?

    private init() {
        UserDefaults.standard.register(defaults: ["presence.battery.enabled": false, "presence.battery.threshold": 20])
        cutoffEnabled = UserDefaults.standard.bool(forKey: "presence.battery.enabled")
        threshold = UserDefaults.standard.integer(forKey: "presence.battery.threshold")
        hasBattery = Self.reading().percent != nil
    }

    func start() {
        guard source == nil, hasBattery else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerWatcher>.fromOpaque(ctx).takeUnretainedValue().check()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        source = src
        check()
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
    }

    private func check() {
        guard cutoffEnabled, source != nil else { return }
        let r = Self.reading()
        if BatteryCutoff.shouldEnd(onBattery: r.onBattery, percent: r.percent, threshold: threshold), let percent = r.percent {
            KeepAwake.shared.endForLowBattery(percent: percent)
        }
    }

    private static func reading() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (onBattery, Int((Double(current) / Double(max) * 100).rounded()))
        }
        return (onBattery, nil)
    }
}
