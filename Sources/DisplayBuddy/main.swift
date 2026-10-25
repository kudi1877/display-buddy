import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var accessibilityTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        AppPrefs.shared.applyDockPolicy()

        // A standard status item, so Bartender / Ice / Hidden Bar can manage it.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "DisplayBuddyStatusItem"
        if let button = statusItem.button {
            button.image = MenuBarIcon.make()
            button.toolTip = "Display Buddy Free"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: PopoverView())
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            self?.popoverAnchorWindow?.orderOut(nil)
        }

        let manager = DisplayManager.shared
        manager.start()
        AppRules.shared.start()

        // Keep Awake + Presentation Mode (Presence/). Started after the display
        // manager so a crash-left presentation can restore display settings.
        Presence.shared.onActiveChange = { [weak self] active in
            self?.statusItem.button?.image = MenuBarIcon.make(active: active)
        }
        Presence.shared.start()

        KeyboardTap.shared.onBrightness = { up, fine in
            let step = fine ? 1.5 : 6.25 // 16 steps across 0...100, like macOS
            manager.step(by: up ? step : -step)
            OSD.shared.show(brightness: manager.shownBrightness, kelvin: manager.currentKelvin)
        }
        Hotkeys.shared.start()
        if !KeyboardTap.shared.start() {
            KeyboardTap.shared.requestPermission()
            waitForAccessibility()
        }
    }

    /// macOS doesn't notify apps when Accessibility is granted, so check
    /// every second until it is, then start listening to the keys.
    func waitForAccessibility() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            if KeyboardTap.shared.start() {
                timer.invalidate()
                self?.accessibilityTimer = nil
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon opens the controls.
        showPopover()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard PresentationMode.shared.isOn else { return .terminateNow }
        // Put presentation changes back before quitting.
        Presence.shared.prepareToQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Presence.shared.shutdown()
        DisplayManager.shared.stop()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        let (view, rect, screen) = popoverAnchor(for: button)
        // Leave room for the arrow and a small gap at the bottom; the content scrolls beyond that.
        PopoverLayout.shared.maxHeight = screen.visibleFrame.height - 40
        popoverAnchorTarget = (view, rect)
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        guard let window = popover.contentViewController?.view.window else { return }
        window.makeKey()
        // SwiftUI settles the content height after the popover opens, and
        // AppKit grows the window upwards, past the top of the screen. Re-anchor
        // after every resize so it always hangs below the menu bar.
        if popoverResizeObserver == nil {
            popoverResizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.reanchorPopover() }
        }
        DispatchQueue.main.async { [weak self] in self?.reanchorPopover() }
    }

    private var popoverAnchorTarget: (NSView, NSRect)?
    private var popoverResizeObserver: NSObjectProtocol?
    private var reanchoring = false

    private func reanchorPopover() {
        guard popover.isShown, !reanchoring, let (view, rect) = popoverAnchorTarget,
              let window = popover.contentViewController?.view.window,
              let screen = window.screen ?? view.window?.screen else { return }
        guard !screen.frame.contains(window.frame) else { return }
        reanchoring = true
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        reanchoring = false
    }

    /// When the menu bar is full, macOS moves status items into a hidden
    /// overflow off-screen (and Bartender/Ice can hide them too). Anchoring to
    /// such a button opens the popover partly outside the screen, so in that
    /// case anchor it under the menu bar of the screen with the mouse instead.
    private func popoverAnchor(for button: NSStatusBarButton) -> (NSView, NSRect, NSScreen) {
        if let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(frame) }) {
                return (button, button.bounds, screen)
            }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let x = min(max(mouse.x, visible.minX + 190), visible.maxX - 190)
        let anchor = popoverAnchorWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .transient]
            popoverAnchorWindow = w
            return w
        }()
        anchor.setFrame(NSRect(x: x, y: visible.maxY - 1, width: 1, height: 1), display: false)
        anchor.orderFrontRegardless()
        let view = anchor.contentView ?? NSView()
        return (view, view.bounds, screen)
    }

    private var popoverAnchorWindow: NSWindow?
}

/// Largest height the popover may use on the screen it opens on.
final class PopoverLayout: ObservableObject {
    static let shared = PopoverLayout()
    @Published var maxHeight: CGFloat = 800
}

/// Menu bar icon: a small monitor with a rising sun, drawn as a "template"
/// image so macOS colours it correctly in light and dark menu bars.
enum MenuBarIcon {
    /// `active` adds a small dot while Keep Awake or Presentation Mode is on.
    static func make(active: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.75, y: 4.75, width: 14.5, height: 10.5), xRadius: 2.2, yRadius: 2.2)
            screen.lineWidth = 1.5
            screen.stroke()
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 6, y: 1.75))
            stand.line(to: NSPoint(x: 12, y: 1.75))
            stand.lineWidth = 1.5
            stand.lineCapStyle = .round
            stand.stroke()
            // Rising sun inside the screen
            let center = NSPoint(x: 9, y: 7.2)
            let sun = NSBezierPath()
            sun.appendArc(withCenter: center, radius: 2.6, startAngle: 0, endAngle: 180)
            sun.close()
            sun.fill()
            for angle in stride(from: 30.0, through: 150.0, by: 60.0) {
                let rad = angle * .pi / 180
                let ray = NSBezierPath()
                ray.move(to: NSPoint(x: center.x + cos(rad) * 3.9, y: center.y + sin(rad) * 3.9))
                ray.line(to: NSPoint(x: center.x + cos(rad) * 5.4, y: center.y + sin(rad) * 5.4))
                ray.lineWidth = 1.2
                ray.lineCapStyle = .round
                ray.stroke()
            }
            if active {
                NSBezierPath(ovalIn: NSRect(x: 13.5, y: 0, width: 4.5, height: 4.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
