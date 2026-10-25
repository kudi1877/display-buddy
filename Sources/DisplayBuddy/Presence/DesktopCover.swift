import AppKit
import PresenceCore

/// Neutral colours for the desktop cover and the presentation wallpaper.
enum NeutralColor: String, CaseIterable, Identifiable {
    case graphite, black, grey
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .graphite: return NSColor(srgbRed: 0.16, green: 0.17, blue: 0.18, alpha: 1)
        case .black: return .black
        case .grey: return NSColor(srgbRed: 0.45, green: 0.46, blue: 0.47, alpha: 1)
        }
    }
}

/// Hides desktop icons by putting one borderless window per screen just above
/// the desktop-icon layer and below every app window (the approach PliimPRO
/// uses). Nothing on disk changes and Finder isn't restarted; if the app
/// quits or crashes the windows disappear with it, so icons can't stay hidden.
final class DesktopCover {
    static let shared = DesktopCover()

    enum Style: Equatable {
        case wallpaper
        case color(NSColor)
    }

    private(set) var isShown = false
    private var style: Style = .wallpaper
    private var windows: [NSWindow] = []
    private var observers: [NSObjectProtocol] = []

    func show(style: Style) {
        self.style = style
        isShown = true
        rebuild()
        guard observers.isEmpty else { return }
        // Plugging in, unplugging or rotating a display changes the screen list.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
    }

    func hide() {
        isShown = false
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func rebuild() {
        guard isShown else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map(makeWindow)
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = CoverPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Clicks land on the cover, so hidden icons can't be dragged by accident.
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.animationBehavior = .none

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        switch style {
        case .color(let color):
            view.layer?.backgroundColor = color.cgColor
        case .wallpaper:
            view.layer?.backgroundColor = Self.fillColor(for: screen).cgColor
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
                view.layer?.contents = image
                view.layer?.contentsGravity = Self.gravity(for: screen)
            }
        }
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        window.orderFront(nil)
        return window
    }

    /// Matches the wallpaper's own fit (fill, fit, stretch, centre).
    private static func gravity(for screen: NSScreen) -> CALayerContentsGravity {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch scaling {
        case .scaleAxesIndependently: return .resize
        case .scaleNone: return .center
        default: return clipping ? .resizeAspectFill : .resizeAspect
        }
    }

    private static func fillColor(for screen: NSScreen) -> NSColor {
        (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor) ?? .black
    }
}

/// A panel that never becomes key, so clicking the cover doesn't activate Display Buddy.
private final class CoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Saves each screen's wallpaper and swaps in a neutral colour; puts it back exactly.
enum Wallpaper {
    static func key(for screen: NSScreen) -> String? {
        guard let id = screen.displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Current wallpapers, or nil plus a reason if any can't be restored exactly.
    static func capture() -> (saved: [ScreenWallpaper]?, problem: String?) {
        var saved: [ScreenWallpaper] = []
        for screen in NSScreen.screens {
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
            let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard let key = key(for: screen), let url, WallpaperPolicy.canRestore(url: url, fileExists: exists) else {
                return (nil, "\(screen.localizedName) has a moving or shuffling wallpaper that can't be put back exactly, so the wallpaper was left as it is.")
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB)
            saved.append(ScreenWallpaper(
                screenKey: key,
                url: url,
                scaling: (options[.imageScaling] as? NSNumber)?.intValue,
                allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fillColor: fill.map { [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)] }))
        }
        return (saved, nil)
    }

    static func applyNeutral(_ color: NSColor) throws {
        let url = try neutralImage(color)
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                .allowClipping: true,
                .fillColor: color,
            ])
        }
    }

    /// Returns the wallpapers that couldn't be restored (their screen isn't connected, or it failed).
    static func restore(_ saved: [ScreenWallpaper]) -> [ScreenWallpaper] {
        var left: [ScreenWallpaper] = []
        for item in saved {
            guard let screen = NSScreen.screens.first(where: { key(for: $0) == item.screenKey }) else { left.append(item); continue }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let s = item.scaling { options[.imageScaling] = s }
            if let c = item.allowClipping { options[.allowClipping] = c }
            if let f = item.fillColor, f.count == 4 {
                options[.fillColor] = NSColor(srgbRed: f[0], green: f[1], blue: f[2], alpha: f[3])
            }
            do {
                try NSWorkspace.shared.setDesktopImageURL(item.url, for: screen, options: options)
            } catch {
                NSLog("Display Buddy: wallpaper restore failed: \(error)")
                left.append(item)
            }
        }
        return left
    }

    /// A tiny solid-colour PNG in Application Support (setDesktopImageURL needs a file).
    private static func neutralImage(_ color: NSColor) throws -> URL {
        let folder = SnapshotStore.defaultURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let name = String(format: "presentation-wallpaper-%02x%02x%02x.png",
                          Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            rgb.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
        return url
    }
}
