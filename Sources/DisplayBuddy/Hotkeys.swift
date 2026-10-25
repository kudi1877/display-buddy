import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts (work in any app, no extra permission):
///   ⌃⌥↑ / ⌃⌥↓   brightness up / down
///   ⌃⌥← / ⌃⌥→   warmer / cooler
///   ⌃⌥1…4       presets Day, Reading, Movie, Night
///   ⌃⌥K / ⌃⌥P   Keep Awake / Presentation Mode (when that module is on)
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hotkeys") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "hotkeys")
            if newValue { register() } else { unregister() }
        }
    }

    func start() {
        installHandler()
        if isEnabled { register() }
    }

    /// Re-registers after a module adds or removes its shortcuts.
    func reload() {
        if isEnabled { register() }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func register() {
        unregister()
        let manager = DisplayManager.shared
        let mods = UInt32(controlKey | optionKey)
        let showOSD = { OSD.shared.show(brightness: manager.shownBrightness, kelvin: manager.currentKelvin) }
        var bindings: [(Int, () -> Void)] = [
            (kVK_UpArrow, { manager.step(by: 6.25); showOSD() }),
            (kVK_DownArrow, { manager.step(by: -6.25); showOSD() }),
            (kVK_LeftArrow, { manager.shiftKelvin(by: -300); showOSD() }),
            (kVK_RightArrow, { manager.shiftKelvin(by: 300); showOSD() }),
        ]
        let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
        for (key, preset) in zip(numberKeys, Preset.allCases) {
            bindings.append((key, { manager.apply(preset: preset); showOSD() }))
        }
        bindings += MainActor.assumeIsolated { Presence.shared.hotkeyBindings }
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4442_4459), id: id) // "DBDY"
            if RegisterEventHotKey(UInt32(binding.0), mods, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
                actions[id] = binding.1
            }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
    }
}
