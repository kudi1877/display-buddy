import Foundation

/// The things presentation mode can change, in the order it applies them:
/// instant, visible changes first; steps that may wait on a permission prompt
/// or the Shortcuts app last. Restoring walks the list backwards.
public enum PresentationStep: String, Codable, CaseIterable, Identifiable {
    case keepAwake
    // Before the cover, so a cover showing the wallpaper shows the new one.
    case wallpaper
    case desktopCover
    case displayPreset
    case alertVolume
    case hideApps
    case focus
    case dockAndMenuBar

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .keepAwake: return "Keep display awake"
        case .focus: return "Do Not Disturb"
        case .dockAndMenuBar: return "Auto-hide Dock and menu bar"
        case .alertVolume: return "Silence alert sounds"
        case .displayPreset: return "Full brightness, neutral colour"
        case .wallpaper: return "Neutral wallpaper"
        case .desktopCover: return "Hide desktop icons"
        case .hideApps: return "Hide other apps"
        }
    }
}

public struct ScreenWallpaper: Codable, Equatable {
    /// Stable per-display identifier (CoreGraphics display UUID).
    public var screenKey: String
    public var url: URL
    /// NSImageScaling raw value.
    public var scaling: Int?
    public var allowClipping: Bool?
    /// sRGB components, 0...1.
    public var fillColor: [Double]?

    public init(screenKey: String, url: URL, scaling: Int?, allowClipping: Bool?, fillColor: [Double]?) {
        self.screenKey = screenKey
        self.url = url
        self.scaling = scaling
        self.allowClipping = allowClipping
        self.fillColor = fillColor
    }
}

public struct DockMenuBarState: Codable, Equatable {
    public var dockAutohide: Bool
    public var menuBarAutohide: Bool

    public init(dockAutohide: Bool, menuBarAutohide: Bool) {
        self.dockAutohide = dockAutohide
        self.menuBarAutohide = menuBarAutohide
    }
}

public struct DisplayState: Codable, Equatable {
    public var brightness: Double
    public var adaptive: Bool
    public var colorMode: String
    public var manualKelvin: Double

    public init(brightness: Double, adaptive: Bool, colorMode: String, manualKelvin: Double) {
        self.brightness = brightness
        self.adaptive = adaptive
        self.colorMode = colorMode
        self.manualKelvin = manualKelvin
    }
}

public struct HiddenApp: Codable, Equatable {
    public var pid: Int32
    public var bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }
}

/// Everything presentation mode needs to put back. Written to disk before any
/// change and again after every step, so a crash can be undone at next launch.
public struct PresentationSnapshot: Codable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var startedAt: Date
    /// Steps that were actually applied and still need restoring.
    public var applied: [PresentationStep]

    public var focusTurnedOn: Bool
    public var dockMenuBar: DockMenuBarState?
    public var alertVolume: Int?
    public var display: DisplayState?
    public var wallpapers: [ScreenWallpaper]
    public var hiddenApps: [HiddenApp]
    public var frontmostApp: HiddenApp?

    public init(startedAt: Date) {
        version = Self.currentVersion
        self.startedAt = startedAt
        applied = []
        focusTurnedOn = false
        wallpapers = []
        hiddenApps = []
    }

    public mutating func markApplied(_ step: PresentationStep) {
        if !applied.contains(step) { applied.append(step) }
    }

    public mutating func markRestored(_ step: PresentationStep) {
        applied.removeAll { $0 == step }
    }

    /// Steps to undo, newest first.
    public var restoreOrder: [PresentationStep] {
        PresentationStep.allCases.reversed().filter { applied.contains($0) }
    }

    /// Nothing left to put back.
    public var isFullyRestored: Bool { applied.isEmpty }
}

/// Saves the snapshot as JSON next to the app's other support files.
public struct SnapshotStore {
    public enum LoadResult: Equatable {
        case none
        case snapshot(PresentationSnapshot)
        /// The file could not be read; it was moved aside to `movedTo`.
        case unreadable(movedTo: URL?)
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    public static func defaultURL(appFolder: String = "Display Buddy Free") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appFolder, isDirectory: true)
            .appendingPathComponent("presentation-state.json")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func save(_ snapshot: PresentationSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    public func load() -> LoadResult {
        guard exists else { return .none }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(PresentationSnapshot.self, from: Data(contentsOf: url))
            return .snapshot(snapshot)
        } catch {
            // Keep the bad file for inspection instead of deleting it, and stop
            // it from being retried on every launch.
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            let moved = (try? FileManager.default.moveItem(at: url, to: aside)) != nil
            return .unreadable(movedTo: moved ? aside : nil)
        }
    }

    public func remove() throws {
        guard exists else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Which apps to hide and which to bring back.
public enum AppHiding {
    public struct RunningApp: Equatable {
        public var pid: Int32
        public var bundleID: String?
        public var isRegular: Bool
        public var isHidden: Bool

        public init(pid: Int32, bundleID: String?, isRegular: Bool, isHidden: Bool) {
            self.pid = pid
            self.bundleID = bundleID
            self.isRegular = isRegular
            self.isHidden = isHidden
        }
    }

    /// Visible regular apps, except our own app and the ones to keep (the presentation app).
    public static func appsToHide(running: [RunningApp], ownPID: Int32, keepBundleIDs: Set<String>) -> [RunningApp] {
        running.filter { app in
            app.isRegular && !app.isHidden && app.pid != ownPID
                && !(app.bundleID.map(keepBundleIDs.contains) ?? false)
        }
    }

    /// Only the apps we hid that are still running and still hidden; apps the
    /// user had hidden before stay hidden.
    /// After a crash or restart a process ID can belong to another app, so the
    /// bundle ID must match too when it is known.
    public static func appsToUnhide(hidden: [HiddenApp], running: [RunningApp]) -> [RunningApp] {
        running.filter { app in
            app.isHidden && hidden.contains { $0.pid == app.pid && ($0.bundleID == nil || $0.bundleID == app.bundleID) }
        }
    }
}

/// Wallpapers that the public API can put back exactly.
public enum WallpaperPolicy {
    /// Moving/shuffling wallpapers (aerials, system wallpaper extensions) and
    /// missing files cannot be restored by URL, so the step is skipped for them.
    public static func canRestore(url: URL?, fileExists: Bool) -> Bool {
        guard let url, url.isFileURL, fileExists else { return false }
        let path = url.path.lowercased()
        let dynamicMarkers = ["idleassetsd", "com.apple.wallpaper", "aerials", "/wallpapers/.thumbnails"]
        return !dynamicMarkers.contains { path.contains($0) }
    }
}

/// Reads the optional "status" shortcut's output (Shortcuts' "Get Current Focus").
public enum FocusStatus {
    /// A non-empty answer is the active Focus's name; empty means no Focus.
    public static func isFocusOn(shortcutOutput: String) -> Bool {
        let text = shortcutOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !(text.isEmpty || text == "none" || text == "off" || text == "no focus")
    }

    public static func missing(required: [String], available: Set<String>) -> [String] {
        required.filter { !$0.isEmpty && !available.contains($0) }
    }
}
