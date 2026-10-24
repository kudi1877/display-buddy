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

        let manager = DisplayManager.shared
        manager.start()
        AppRules.shared.start()

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

    func applicationWillTerminate(_ notification: Notification) {
        DisplayManager.shared.stop()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// Menu bar icon: a small monitor with a rising sun, drawn as a "template"
/// image so macOS colours it correctly in light and dark menu bars.
enum MenuBarIcon {
    static func make() -> NSImage {
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
