# Display Buddy

A free macOS menu bar app to control external monitors: synced brightness, Apple keyboard brightness keys, sub-zero dimming and automatic colour temperature. Built for a closed-lid MacBook with three external monitors.

**Install:** see [INSTALL.md](INSTALL.md).

## Features
- Brightness sync across all external monitors, with a per-monitor "Match" offset
- Apple keyboard brightness keys (F1/F2) with an on-screen indicator
- Sub-zero dimming below the monitor's hardware minimum
- Colour temperature: manual, or follows sunrise/sunset; warmer when dimmed
- Contrast control
- Works with Bartender / Ice / Hidden Bar; optional Dock icon; open at login
- Settings remembered per monitor (home and work setups)

## How it works
- **Hardware brightness:** DDC/CI over the monitor cable (Apple Silicon `IOAVService`), the approach used by [MonitorControl](https://github.com/MonitorControl/MonitorControl) and [m1ddc](https://github.com/waydabber/m1ddc).
- **Sub-zero and colour temperature:** display gamma tables.
- **Keys:** a CoreGraphics event tap (needs Accessibility permission).

## Build
GitHub Actions builds the app on every push to `main` and publishes it as the `latest` release. To build on a Mac by hand: `./scripts/build-app.sh`.

## Roadmap
Planned in stages (bundles): Intel Mac DDC support, home/work profiles, volume and input switching, custom hotkeys, presets, adaptive brightness schedule.
