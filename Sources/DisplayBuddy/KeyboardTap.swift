import AppKit
import ApplicationServices
import CoreGraphics

/// Listens for the Apple keyboard's brightness keys (F1/F2) and uses them for
/// the external monitors. This needs the Accessibility permission, which
/// macOS asks for the first time.
final class KeyboardTap {
    static let shared = KeyboardTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var onBrightness: ((_ up: Bool, _ fine: Bool) -> Void)?

    private let nxSysDefined: UInt32 = 14
    private let nxKeyBrightnessUp = 2
    private let nxKeyBrightnessDown = 3
    // Some keyboards and macOS versions send the keys as normal key codes.
    private let kcBrightnessUp: Int64 = 144
    private let kcBrightnessDown: Int64 = 145

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard isTrusted else { return false }
        let mask: CGEventMask = (1 << CGEventMask(nxSysDefined)) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<KeyboardTap>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)

        if type.rawValue == nxSysDefined {
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = (ns.data1 & 0xFFFF_0000) >> 16
            let keyDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
            guard keyCode == nxKeyBrightnessUp || keyCode == nxKeyBrightnessDown else {
                return Unmanaged.passUnretained(event)
            }
            if keyDown { fire(up: keyCode == nxKeyBrightnessUp, fine: fine) }
            return nil // swallow so macOS doesn't show "no display" feedback
        }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == kcBrightnessUp || code == kcBrightnessDown else { return Unmanaged.passUnretained(event) }
        if type == .keyDown { fire(up: code == kcBrightnessUp, fine: fine) }
        return nil
    }

    private func fire(up: Bool, fine: Bool) {
        DispatchQueue.main.async { self.onBrightness?(up, fine) }
    }
}
