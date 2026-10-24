import CoreGraphics
import Foundation

/// Resolution and rotation quick-switch.
///
/// Resolution uses the public CoreGraphics display-mode API. Rotation has no
/// public API, so it goes through Apple's private MonitorPanel framework (the
/// one System Settings uses), loaded at runtime: if a future macOS removes it,
/// the rotation menu simply disappears instead of the app crashing.
enum DisplayLayout {
    struct Resolution: Identifiable, Hashable {
        let width: Int, height: Int, hiDPI: Bool
        fileprivate let mode: CGDisplayMode
        var id: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }
        var label: String { "\(width) × \(height)" }
        static func == (a: Resolution, b: Resolution) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    /// Desktop resolutions for a display, largest first. One entry per size
    /// (HiDPI and regular kept apart), at the highest refresh rate available.
    static func resolutions(for display: CGDirectDisplayID) -> [Resolution] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return [] }
        var best: [String: Resolution] = [:]
        for mode in modes where mode.isUsableForDesktopGUI() {
            let r = Resolution(width: mode.width, height: mode.height, hiDPI: mode.pixelWidth > mode.width, mode: mode)
            if let existing = best[r.id], existing.mode.refreshRate >= mode.refreshRate { continue }
            best[r.id] = r
        }
        return best.values.sorted { ($0.width * $0.height, $0.hiDPI ? 1 : 0) > ($1.width * $1.height, $1.hiDPI ? 1 : 0) }
    }

    static func current(for display: CGDirectDisplayID) -> Resolution? {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        return Resolution(width: mode.width, height: mode.height, hiDPI: mode.pixelWidth > mode.width, mode: mode)
    }

    @discardableResult
    static func set(_ resolution: Resolution, on display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, resolution.mode, nil)
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    // MARK: Rotation (private MonitorPanel framework)

    static let rotations = [0, 90, 180, 270]

    private typealias IntGetter = @convention(c) (AnyObject, Selector) -> Int
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool
    private typealias IntSetter = @convention(c) (AnyObject, Selector, Int32) -> Void

    private static let monitorPanelLoaded: Bool =
        dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil

    private static func panelDisplay(for display: CGDirectDisplayID) -> NSObject? {
        guard monitorPanelLoaded, let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let manager = cls.init()
        guard let displays = manager.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { (intValue($0, "displayID") ?? -1) == Int(display) }
    }

    private static func intValue(_ object: NSObject, _ name: String) -> Int? {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel) else { return nil }
        return unsafeBitCast(object.method(for: sel), to: IntGetter.self)(object, sel)
    }

    static func canRotate(_ display: CGDirectDisplayID) -> Bool {
        let sel = NSSelectorFromString("canChangeOrientation")
        guard let d = panelDisplay(for: display), d.responds(to: sel),
              d.responds(to: NSSelectorFromString("setOrientation:")) else { return false }
        return unsafeBitCast(d.method(for: sel), to: BoolGetter.self)(d, sel)
    }

    static func rotation(of display: CGDirectDisplayID) -> Int { Int(CGDisplayRotation(display)) }

    static func rotate(_ display: CGDirectDisplayID, to degrees: Int) {
        let sel = NSSelectorFromString("setOrientation:")
        guard rotations.contains(degrees), let d = panelDisplay(for: display), d.responds(to: sel) else { return }
        unsafeBitCast(d.method(for: sel), to: IntSetter.self)(d, sel, Int32(degrees))
    }
}
