import AppKit
import SwiftUI

/// The small rounded brightness indicator that appears when you press the
/// brightness keys, styled like the one built into macOS.
final class OSD {
    static let shared = OSD()
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var hideWork: DispatchWorkItem?

    func show(brightness: Double, kelvin: Double) {
        hideWork?.cancel()
        for screen in NSScreen.screens {
            guard let id = screen.displayID, CGDisplayIsBuiltin(id) == 0 else { continue }
            let panel = panels[id] ?? makePanel()
            panels[id] = panel
            panel.contentView = NSHostingView(rootView: OSDView(brightness: brightness, kelvin: kelvin))
            let size = NSSize(width: 200, height: 200)
            let frame = screen.frame
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.14, width: size.width, height: size.height), display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self?.panels.values.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                self?.panels.values.forEach { $0.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

struct OSDView: View {
    let brightness: Double
    let kelvin: Double

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: brightness < 0 ? "moon.fill" : "sun.max.fill")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(brightness < 0 ? Color.indigo : Color.orange)
                .symbolRenderingMode(.hierarchical)
            BrightnessBar(value: brightness)
                .frame(width: 150, height: 8)
            Text(brightness < 0 ? "Sub-zero \(Int(brightness))" : "\(Int(brightness))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct BrightnessBar: View {
    let value: Double // -100...100
    var body: some View {
        GeometryReader { geo in
            let zeroX = geo.size.width / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15))
                if value >= 0 {
                    Capsule().fill(Color.primary.opacity(0.85))
                        .frame(width: zeroX + zeroX * value / 100)
                } else {
                    Capsule().fill(Color.indigo.opacity(0.85))
                        .frame(width: max(4, zeroX * (1 + value / 100)))
                }
            }
        }
    }
}
