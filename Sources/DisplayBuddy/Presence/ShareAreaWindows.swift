import AppKit

// MARK: - Frame overlay

/// The landscape frame drawn over the shared area: a click-through border, a
/// handle above it to move it (with the size and a Stop button), and a grip at
/// the bottom-right corner to resize it. None of these windows are captured.
@MainActor
final class ShareFrameController {
    private(set) var rect: NSRect
    private var aspect: CGFloat
    var onChange: ((NSRect) -> Void)?
    var onStop: (() -> Void)?

    private let border: NSPanel
    private let handle: NSPanel
    private let grip: NSPanel
    private let sizeLabel = NSTextField(labelWithString: "")
    private static let borderWidth: CGFloat = 4
    private static let snap: CGFloat = 14
    private static let minWidth: CGFloat = 320

    init(rect: NSRect, aspect: CGFloat) {
        self.rect = rect
        self.aspect = aspect
        border = Self.panel(clickThrough: true)
        handle = Self.panel(clickThrough: false)
        grip = Self.panel(clickThrough: false)

        border.contentView = BorderView()

        let move = DragView { [weak self] dx, dy, ended in self?.drag(dx: dx, dy: dy, resize: false, ended: ended) }
        move.wantsLayer = true
        move.layer?.backgroundColor = NSColor.systemOrange.cgColor
        move.layer?.cornerRadius = 6
        sizeLabel.textColor = .white
        sizeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let title = NSTextField(labelWithString: "⠿  Shared area")
        title.textColor = .white
        title.font = .systemFont(ofSize: 11, weight: .bold)
        let stop = NSButton(title: "Stop", target: nil, action: nil)
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        let stack = NSStackView(views: [title, sizeLabel, stop])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 10, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        move.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: move.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: move.trailingAnchor),
            stack.topAnchor.constraint(equalTo: move.topAnchor),
            stack.bottomAnchor.constraint(equalTo: move.bottomAnchor),
        ])
        handle.contentView = move
        stop.target = StopTarget.shared
        stop.action = #selector(StopTarget.stop)
        StopTarget.shared.handler = { [weak self] in self?.onStop?() }

        let resize = DragView { [weak self] dx, dy, ended in self?.drag(dx: dx, dy: dy, resize: true, ended: ended) }
        resize.wantsLayer = true
        resize.layer?.backgroundColor = NSColor.systemOrange.cgColor
        resize.layer?.cornerRadius = 4
        resize.toolTip = "Drag to resize"
        grip.contentView = resize
    }

    func show() {
        layout()
        [border, handle, grip].forEach { $0.orderFrontRegardless() }
    }

    func close() {
        [border, handle, grip].forEach { $0.orderOut(nil) }
    }

    func setAspect(_ newAspect: CGFloat) {
        aspect = newAspect
        // Keep the width and top edge, change the height.
        let height = (rect.width / aspect).rounded()
        rect = NSRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        rect = constrained(rect)
        layout()
        onChange?(rect)
    }

    // MARK: Dragging

    private var dragStart: NSRect?

    private func drag(dx: CGFloat, dy: CGFloat, resize: Bool, ended: Bool) {
        let start = dragStart ?? rect
        dragStart = start
        var next: NSRect
        if resize {
            // The top-left corner stays put; width follows the mouse, height follows the aspect ratio.
            let width = max(Self.minWidth, start.width + dx)
            let height = (width / aspect).rounded()
            next = NSRect(x: start.minX, y: start.maxY - height, width: width.rounded(), height: height)
        } else {
            next = start.offsetBy(dx: dx, dy: dy)
        }
        rect = constrained(snapped(next))
        layout()
        if ended {
            dragStart = nil
            onChange?(rect)
        }
    }

    /// Pulls edges that come close to the screen's edges onto them.
    private func snapped(_ r: NSRect) -> NSRect {
        guard let screen = Self.screen(containing: r) else { return r }
        let v = screen.visibleFrame
        var r = r
        if abs(r.minX - v.minX) < Self.snap { r.origin.x = v.minX }
        if abs(r.maxX - v.maxX) < Self.snap { r.origin.x = v.maxX - r.width }
        if abs(r.maxY - v.maxY) < Self.snap { r.origin.y = v.maxY - r.height }
        if abs(r.minY - v.minY) < Self.snap { r.origin.y = v.minY }
        return r
    }

    /// Keeps the frame inside one screen and no wider than it.
    private func constrained(_ r: NSRect) -> NSRect {
        guard let screen = Self.screen(containing: r) else { return r }
        let f = screen.frame
        var r = r
        if r.width > f.width {
            r.size = NSSize(width: f.width, height: (f.width / aspect).rounded())
        }
        r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
        r.origin.y = min(max(r.minY, f.minY), f.maxY - r.height)
        return r
    }

    private static func screen(containing r: NSRect) -> NSScreen? {
        let center = NSPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }

    private func layout() {
        let b = Self.borderWidth
        border.setFrame(rect.insetBy(dx: -b, dy: -b), display: true)
        let scale = Self.screen(containing: rect)?.backingScaleFactor ?? 2
        sizeLabel.stringValue = "\(Int(rect.width * scale)) × \(Int(rect.height * scale))"
        let handleSize = handle.contentView?.fittingSize ?? NSSize(width: 260, height: 26)
        // Above the frame, or just inside its top edge when there's no room above.
        var handleY = rect.maxY + b + 2
        if let screen = Self.screen(containing: rect), handleY + handleSize.height > screen.frame.maxY {
            handleY = rect.maxY - handleSize.height - 2
        }
        handle.setFrame(NSRect(x: rect.minX - b, y: handleY, width: handleSize.width, height: handleSize.height), display: true)
        grip.setFrame(NSRect(x: rect.maxX - 6, y: rect.minY - 10, width: 16, height: 16), display: true)
    }

    private static func panel(clickThrough: Bool) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = clickThrough
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        // Never part of anyone's screen capture or screen share.
        p.sharingType = .none
        return p
    }
}

/// Draws the orange outline around the shared area.
private final class BorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4)
        path.lineWidth = 3
        path.setLineDash([10, 5], count: 2, phase: 0)
        path.stroke()
    }
}

/// Reports mouse drags in screen coordinates, relative to where the drag started.
private final class DragView: NSView {
    private let onDrag: (CGFloat, CGFloat, Bool) -> Void
    private var start: NSPoint?

    init(onDrag: @escaping (CGFloat, CGFloat, Bool) -> Void) {
        self.onDrag = onDrag
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Buttons keep their clicks; everything else (labels, background) drags.
        let hit = super.hitTest(point)
        return hit is NSButton ? hit : (hit == nil ? nil : self)
    }

    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let now = NSEvent.mouseLocation
        onDrag(now.x - start.x, now.y - start.y, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let now = NSEvent.mouseLocation
        onDrag(now.x - start.x, now.y - start.y, true)
        self.start = nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

private final class StopTarget: NSObject {
    static let shared = StopTarget()
    var handler: (() -> Void)?
    @objc func stop() { handler?() }
}

// MARK: - Mirror window

/// The window call apps share: a live copy of the framed area. It may sit
/// behind other windows or on another screen; minimised windows can't be shared.
@MainActor
final class ShareMirrorWindow: NSObject, NSWindowDelegate {
    let imageLayer = CALayer()
    var onClose: (() -> Void)?
    var onMinimizeChange: ((Bool) -> Void)?
    private let window: NSWindow
    private var closingQuietly = false

    init(title: String, aspect: CGFloat, avoiding frameScreen: NSScreen) {
        // Prefer a screen other than the one being shared, so the copy doesn't cover the area.
        let target = NSScreen.screens.first { $0 != frameScreen } ?? frameScreen
        let width = min(1280, target.visibleFrame.width * 0.85).rounded()
        let size = NSSize(width: width, height: (width / aspect).rounded())
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = size
        window.delegate = self
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.frame = view.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
        window.contentView = view
        let v = target.visibleFrame
        window.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.minY + 40))
    }

    func show() {
        window.orderFrontRegardless()
    }

    func setAspect(_ aspect: CGFloat) {
        let width = window.contentLayoutRect.width
        let size = NSSize(width: width, height: (width / aspect).rounded())
        window.contentAspectRatio = size
        window.setContentSize(size)
    }

    /// Closed by Display Buddy (Stop), not by the user.
    func closeQuietly() {
        closingQuietly = true
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !closingQuietly { onClose?() }
    }

    func windowDidMiniaturize(_ notification: Notification) { onMinimizeChange?(true) }
    func windowDidDeminiaturize(_ notification: Notification) { onMinimizeChange?(false) }
}
