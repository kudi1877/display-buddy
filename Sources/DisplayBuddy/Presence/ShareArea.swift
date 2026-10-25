import AppKit
import ScreenCaptureKit

/// "Share area": a landscape frame you place over part of a (portrait) screen,
/// mirrored live into a normal window that any call app can share with
/// "Share window" (Teams, Zoom, Slack, Discord, Meet, Whereby). Uses Apple's
/// public ScreenCaptureKit, so it needs the Screen Recording permission.
@MainActor
final class ShareArea: ObservableObject {
    static let shared = ShareArea()

    enum Aspect: String, CaseIterable, Identifiable {
        case wide169, wide1610, classic43
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wide169: return "16:9"
            case .wide1610: return "16:10"
            case .classic43: return "4:3"
            }
        }
        /// Width divided by height.
        var ratio: CGFloat {
            switch self {
            case .wide169: return 16.0 / 9
            case .wide1610: return 16.0 / 10
            case .classic43: return 4.0 / 3
            }
        }
    }

    enum Problem: Equatable {
        case needsPermission
        case minimized
        case failed(String)

        var text: String {
            switch self {
            case .needsPermission:
                return "Display Buddy needs the Screen Recording permission to copy the area. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording, then click Share area again (if it still doesn't start, quit and reopen Display Buddy)."
            case .minimized:
                return "The “\(ShareArea.mirrorTitle)” window is minimised, so call apps can't share it. Bring it back (it can sit behind other windows or on another screen)."
            case .failed(let message):
                return "Sharing stopped: \(message)"
            }
        }
    }

    nonisolated static let mirrorTitle = "Display Buddy — Shared area"

    @Published private(set) var isRunning = false
    @Published private(set) var problem: Problem?
    @Published var aspect: Aspect {
        didSet {
            defaults.set(aspect.rawValue, forKey: "presence.shareArea.aspect")
            frame?.setAspect(aspect.ratio)
            mirror?.setAspect(aspect.ratio)
        }
    }
    @Published var showsCursor: Bool {
        didSet {
            defaults.set(showsCursor, forKey: "presence.shareArea.cursor")
            Task { await updateStream() }
        }
    }
    @Published var startWithPresentation: Bool {
        didSet { defaults.set(startWithPresentation, forKey: "presence.shareArea.withPresentation") }
    }

    private let defaults = UserDefaults.standard
    private var frame: ShareFrameController?
    private var mirror: ShareMirrorWindow?
    private var stream: SCStream?
    private var output: ShareStreamOutput?
    private var streamDisplayID: CGDirectDisplayID?
    private var startedByPresentation = false

    private init() {
        defaults.register(defaults: [
            "presence.shareArea.aspect": Aspect.wide169.rawValue,
            "presence.shareArea.cursor": true,
            "presence.shareArea.withPresentation": false,
        ])
        aspect = Aspect(rawValue: defaults.string(forKey: "presence.shareArea.aspect") ?? "") ?? .wide169
        showsCursor = defaults.bool(forKey: "presence.shareArea.cursor")
        startWithPresentation = defaults.bool(forKey: "presence.shareArea.withPresentation")
    }

    // MARK: Start / stop

    func toggle() {
        if isRunning { stop() } else { Task { await start() } }
    }

    func startForPresentation() async {
        guard startWithPresentation, !isRunning else { return }
        await start()
        startedByPresentation = isRunning
    }

    func stopForPresentation() {
        if startedByPresentation { stop() }
    }

    func start() async {
        guard !isRunning else { return }
        problem = nil
        // The system prompt appears once; after that the user flips the switch in Settings.
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            problem = .needsPermission
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let rect = savedRect(on: screen) ?? defaultRect(on: screen)

        let mirror = ShareMirrorWindow(title: Self.mirrorTitle, aspect: aspect.ratio, avoiding: screen)
        mirror.onClose = { [weak self] in self?.stop() }
        mirror.onMinimizeChange = { [weak self] minimized in
            guard let self else { return }
            if minimized { self.problem = .minimized } else if self.problem == .minimized { self.problem = nil }
        }
        self.mirror = mirror

        let frame = ShareFrameController(rect: rect, aspect: aspect.ratio)
        frame.onChange = { [weak self] rect in self?.frameMoved(to: rect) }
        frame.onStop = { [weak self] in self?.stop() }
        self.frame = frame

        isRunning = true
        mirror.show()
        frame.show()
        await restartStream()
    }

    func stop() {
        startedByPresentation = false
        let oldStream = stream, oldOutput = output
        stream = nil
        output = nil
        streamDisplayID = nil
        // Keep the frame receiver alive until the stream has really stopped.
        Task {
            try? await oldStream?.stopCapture()
            withExtendedLifetime(oldOutput) {}
        }
        frame?.close()
        frame = nil
        mirror?.closeQuietly()
        mirror = nil
        isRunning = false
        if problem == .minimized { problem = nil }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Frame

    private func frameMoved(to rect: NSRect) {
        guard let screen = screen(for: rect) else { return }
        save(rect, on: screen)
        Task {
            if screen.displayID != streamDisplayID { await restartStream() } else { await updateStream() }
        }
    }

    private func screen(for rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    private func defaultRect(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = (visible.width * 0.9).rounded()
        let height = (width / aspect.ratio).rounded()
        return NSRect(x: visible.midX - width / 2, y: visible.maxY - height - visible.height * 0.15, width: width, height: height)
    }

    /// Remembered per screen, relative to the screen, so home and work desks each keep theirs.
    private func savedRect(on screen: NSScreen) -> NSRect? {
        guard let key = Wallpaper.key(for: screen),
              let all = defaults.dictionary(forKey: "presence.shareArea.frames") as? [String: [Double]],
              let v = all[key], v.count == 4 else { return nil }
        let width = CGFloat(v[2])
        let rect = NSRect(x: screen.frame.minX + CGFloat(v[0]), y: screen.frame.minY + CGFloat(v[1]), width: width, height: width / aspect.ratio)
        return screen.frame.contains(rect) ? rect : nil
    }

    private func save(_ rect: NSRect, on screen: NSScreen) {
        guard let key = Wallpaper.key(for: screen) else { return }
        var all = defaults.dictionary(forKey: "presence.shareArea.frames") as? [String: [Double]] ?? [:]
        all[key] = [rect.minX - screen.frame.minX, rect.minY - screen.frame.minY, rect.width, rect.height].map(Double.init)
        defaults.set(all, forKey: "presence.shareArea.frames")
    }

    // MARK: Capture

    /// Builds a new stream for the display the frame is on.
    private func restartStream() async {
        guard isRunning, let frame, let mirror, let screen = screen(for: frame.rect), let displayID = screen.displayID else { return }
        if let old = stream {
            let oldOutput = output
            stream = nil
            try? await old.stopCapture()
            withExtendedLifetime(oldOutput) {}
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CocoaError(.featureUnsupported)
            }
            // Leave out all of Display Buddy's own windows (the mirror itself,
            // the frame, menus), so the copy never shows itself.
            let own = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = configuration(for: frame.rect, on: screen)
            let output = ShareStreamOutput(layer: mirror.imageLayer)
            output.onStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.problem = .failed(error.localizedDescription)
                    self.stop()
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            guard isRunning else { try? await stream.stopCapture(); return }
            self.stream = stream
            self.output = output
            streamDisplayID = displayID
        } catch {
            problem = CGPreflightScreenCaptureAccess() ? .failed(error.localizedDescription) : .needsPermission
            stop()
        }
    }

    private func updateStream() async {
        guard let stream, let frame, let screen = screen(for: frame.rect) else { return }
        try? await stream.updateConfiguration(configuration(for: frame.rect, on: screen))
    }

    private func configuration(for rect: NSRect, on screen: NSScreen) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // ScreenCaptureKit wants the area in the display's own points, origin at the top left.
        let local = rect.intersection(screen.frame)
        config.sourceRect = CGRect(x: local.minX - screen.frame.minX, y: screen.frame.maxY - local.maxY,
                                   width: local.width, height: local.height)
        let scale = screen.backingScaleFactor
        config.width = Int(local.width * scale)
        config.height = Int(local.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }
}

/// Receives frames on a background queue and hands the IOSurface to the mirror's layer.
final class ShareStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "DisplayBuddy.ShareArea", qos: .userInteractive)
    var onStop: ((Error) -> Void)?
    private weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
