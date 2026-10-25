# Display Buddy

A free macOS menu bar app to control external monitors: synced brightness, Apple keyboard brightness keys, sub-zero dimming and automatic colour temperature. Built for a closed-lid MacBook with three external monitors.

**Install:** see [INSTALL.md](INSTALL.md).

## Features
- Brightness sync across all external monitors, with a per-monitor "Match" offset
- Apple keyboard brightness keys (F1/F2) with an on-screen indicator
- Sub-zero dimming below the monitor's hardware minimum
- Colour temperature: manual, or follows sunrise/sunset; warmer when dimmed
- Contrast control
- Per-app brightness: chosen apps get their own brightness while they are in front
- Resolution and rotation quick-switch per monitor (monitor menu ⋯)
- Keep Awake (optional module): keep the display on, or let it sleep while the Mac stays awake; 15 min to 4 h, indefinitely, custom or until a set time; stays awake while chosen apps run; optional low-battery cut-off; ⌃⌥K
- Presentation mode (same module): hides desktop icons on every screen, turns on Do Not Disturb (via two Shortcuts), auto-hides the Dock and menu bar and keeps the display awake. Optionally it also silences alert sounds, sets a neutral wallpaper, sets full brightness with neutral colour, and hides other apps. Everything is put back exactly afterwards, even after a crash; ⌃⌥P
- Share area (same module): share a landscape part of a vertical screen in any call app (Teams, Zoom, Slack, Discord, Meet, Whereby) via “Share window”. Uses ScreenCaptureKit and needs the Screen Recording permission.
- Works with Bartender / Ice / Hidden Bar; optional Dock icon; open at login
- Settings remembered per monitor (home and work setups)

## How it works
- **Hardware brightness:** DDC/CI over the monitor cable (Apple Silicon `IOAVService`), the approach used by [MonitorControl](https://github.com/MonitorControl/MonitorControl) and [m1ddc](https://github.com/waydabber/m1ddc).
- **Sub-zero and colour temperature:** display gamma tables.
- **Rotation:** Apple's private MonitorPanel framework (what System Settings uses), loaded at runtime; resolution uses the public CoreGraphics display-mode API.
- **Keys:** a CoreGraphics event tap (needs Accessibility permission).
- **Keep Awake:** one public IOKit power assertion (display-sleep or system-sleep).
- **Presentation mode:**
  - Desktop icons are covered by a window just above the desktop-icon layer (no Finder restart).
  - The Dock and menu bar are auto-hidden via System Events (needs Automation permission).
  - Do Not Disturb runs through the `shortcuts` command-line tool.
  - Previous values are saved to `~/Library/Application Support/Display Buddy Free/presentation-state.json` before anything changes.
  - See [docs/research/presence-module.md](docs/research/presence-module.md).

## Build
GitHub Actions builds the app on every push to `main` and publishes it as the `latest` release. To build on a Mac by hand: `./scripts/build-app.sh`.

## Roadmap
Planned in stages (bundles): Intel Mac DDC support, home/work profiles, volume and input switching, custom hotkeys, presets, adaptive brightness schedule.
