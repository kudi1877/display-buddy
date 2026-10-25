# Presence module: clean-room study of Lungo and PliimPRO

Phase 0 research for Display Buddy Free (Linear TIN-1065). Date: 2026-10-24. Test machine: Apple Silicon Mac, macOS 26.5.2, three external 32-inch displays in portrait (1440×2560 pt each, arranged left / main / right).

Targets (Setapp builds, left unmodified):

| App | Version | Distribution | Developer |
|---|---|---|---|
| Lungo | 2.8.3 (build 46) | Setapp build | independent developer |
| PliimPRO | 1.7 (build 9, built Oct 2023 with the macOS 14 SDK) | Setapp build | independent developer |

This file describes behaviour and mechanisms in my own words. It contains no decompiled code, pseudocode, copied strings, UI text or images. Everything here comes from public-API inspection (imports, linked frameworks, signing), observed runtime behaviour, and system state diffs.

---

## 0. Method and tooling

**REA (morluto/rea)** was already installed as an MCP server in this session (`mcp__rea__*`), so nothing had to be installed.

| Step | Tool used | Notes |
|---|---|---|
| Signature, entitlements, hardened runtime | REA `inspect_signature` (PliimPRO); `codesign -d --entitlements` (Lungo) | |
| Info.plist | REA `inspect_plist` (PliimPRO); `plutil` (Lungo) | |
| Linked frameworks and imported symbols | Fallback: `otool -L`, `nm -u` | |
| Strings and class names | Fallback: `strings` and `grep` | Kept local for analysis only. Nothing copied into this doc. |
| Procedures and cross-references | REA + Ghidra on a thinned arm64 copy of PliimPRO in a temporary folder (`search_procedures`, `find_xrefs_to_name`, `analyze_function`) | Used only to see which APIs each routine calls. The universal binary had to be thinned for Ghidra. Hopper and IDA aren't installed. |
| UI mapping | **Fallback**: my own small Swift Accessibility dumper and presser, run from the shell (which is AX-trusted) | REA `observe_native_ui` refused both apps' windows ("window-mismatch"). On macOS 26, status-bar items are scenes hosted by Control Center, and SwiftUI panels aren't listed per process. Screen capture of windows was also blocked: the shell has no Screen Recording permission. |
| Process capture | REA `capture_process_scenario` attempted | The run executed, but REA reported a cleanup error because the scenario launched long-lived apps. Final process observations came from **fallback** `ps` polling (0.1–0.25 s), filtered to children of the target PID. |
| Power assertions | `pmset -g assertions` before, during and after every step | |
| System state | `defaults read`, System Events (wallpaper, volumes, app visibility), Control Center AX tree (Focus indicator), `log show` / `log stream` (donotdisturbd) | `~/Library/DoNotDisturb/DB/*` is blocked by privacy protection (TCC) for the shell. Focus state was read from Control Center's menu bar Focus indicator and from donotdisturbd logs. |

**Driving the apps:**
- **Lungo:** driven through its own URL scheme (`lungo:activate`, `lungo:deactivate`, `lungo:toggle`, with `minutes`/`hours`) and its Settings window (via AX).
- **PliimPRO:** its menu bar icon was unreachable. Both apps' icons sit in macOS's hidden overflow because the menu bar is full. Pressing PliimPRO's status button through Accessibility **crashed PliimPRO** (Swift trap in its click handler; crash report kept).
  - So I temporarily set PliimPRO's own global-shortcut preference (⌃⌥⌘P), toggled it with a synthetic key event, and deleted the preference afterwards.

---

## 1. Bundle, permissions and packaging

| | Lungo | PliimPRO |
|---|---|---|
| App Sandbox | **Yes** (network client, plus a mach-lookup exception for Setapp's provisioning service) | **No** |
| Hardened runtime | yes | yes |
| Entitlements of note | none beyond sandbox/network | audio input (microphone), for the mic-mute feature |
| Apple Events / Automation | none; no Apple-events usage description | none. There's no Apple-events entitlement, so it can't script Finder or System Events under hardened runtime. |
| Accessibility (TCC) | not needed | **needed** for its DND method on macOS 12+. It checks trust and offers the system prompt. |
| Agent app (no Dock icon) | yes | yes |
| Minimum OS | macOS 26.0 | macOS 10.15 |
| Helpers / login items | none bundled; uses ServiceManagement (modern login-item API) | bundled login-item helper app (old-style helper approach), plus the modern login-item API on newer OS |
| Embedded frameworks | none | **DFRFoundation**: Apple's *private* Touch Bar framework, re-signed by the developer and bundled |
| URL scheme | yes (`lungo:`): activate / deactivate / toggle, optional minutes/hours | none |
| Shortcuts / App Intents | yes: set on/off, read on/off, read remaining time, adjust time | none |
| Global hotkeys | yes (Carbon hotkey via the KeyboardShortcuts library); default unset | yes (same library): a presentation toggle and a mic-mute toggle; default unset |
| Other frameworks | IOKit power (assertions and power-source notifications), UserNotifications, Combine/SwiftUI, iCloud key-value sync | IOKit, CoreAudio, CoreGraphics events, Carbon, NSWorkspace |

---

## 2. Lungo: feature checklist and mechanisms

### Feature checklist (observed in its menu and settings)

**Activation**
- [x] Activate / deactivate keep-awake.
- [x] Durations: indefinite (default), 10 min, 30 min, 1 h, 2 h, 4 h, 8 h, 12 h. Also a custom duration and an "until a clock time" option (seen in strings and intents).
- [x] Default-duration setting.
- [x] Activate when the app launches.
- [x] Launch at login.
- [x] Click behaviour: left-click activates and right-click opens the menu, or the reverse.

**Sleep behaviour**
- [x] Option to let the display sleep while keeping the computer awake.
- [x] Option to allow sleep while the screen is locked (pauses keep-awake on lock).
- [x] Option to deactivate when the Mac switches to battery. It does not re-activate on AC.

**Menu bar icon**
- [x] Active-state icon style: normal, green or blue badge, green or blue fill.
- [x] Option to dim the icon while inactive.
- [x] Warning when macOS has hidden its menu bar icon in the overflow (this fired on this Mac).

**Integration**
- [x] Global toggle shortcut.
- [x] Shortcuts app actions (App Intents) and a URL scheme for automation.
- [x] Experimental high-accuracy timer.
- [x] Settings synced via iCloud key-value store.

### Mechanism

- **Keep-awake** is a single IOKit power assertion created by name. There's no `caffeinate`, no `pmset`, and no child process. It couldn't spawn them anyway, being sandboxed.
- **Display vs system mode** depends only on the "let display sleep" setting. Observed with `pmset -g assertions`:
  - **Setting off (default):** one **PreventUserIdleDisplaySleep** assertion. This also keeps the system awake.
  - **Setting on:** one **PreventUserIdleSystemSleep** assertion. The display may sleep and the Mac stays awake.
  - URL parameters don't override this choice. I tried several parameter names and none changed the assertion type.
- **Timer:** a 1-minute activation released its assertion on its own between 53 s and 103 s after start. Lungo deactivates by releasing the assertion; there's no lingering assertion.
- **Battery auto-deactivate:** IOKit power-source notifications. Lungo also watches low-power mode and thermal-state changes.
- **Pause on screen lock:** listens for the system-wide screen-locked / unlocked distributed notifications.
- **Sleep/wake bookkeeping:** NSWorkspace will-sleep / did-wake notifications.
- **Notifications:** posts a user notification when keep-awake ends.

---

## 3. PliimPRO: feature checklist and mechanisms

### Feature checklist

The status menu couldn't be opened here, so these come from its preference keys, symbols and observed behaviour.

- [x] One toggle for "presentation mode", from the menu bar icon, a global shortcut, or a Touch Bar button.
- [x] Sub-features, each a stored on/off setting:
  1. Hide desktop icons (on here).
  2. Hide all other apps (on here).
  3. Disable notifications, i.e. DND (on here).
  4. Mute the speakers (off here).
  5. Use a custom wallpaper image while in presentation mode (off here).
- [x] Separate global shortcut to mute or unmute the microphone, with an on-screen mute indicator window.
- [x] Watches the frontmost app (application-activated notifications). It also has per-app allow logic tied to the DND check. I didn't observe what this drives; it may be auto-behaviour for presentation apps (unconfirmed).
- [x] Launch at login.
- [x] Touch Bar control-strip button (private DFRFoundation).

### Mechanisms and the specific questions

**How does it hide desktop icons? An overlay window, not a Finder restart.**
- While active, PliimPRO created **one borderless window per display**, covering the whole screen (three windows: −1440/0/+1440, each 1440×2560).
- Each window holds a single image view, filled with that screen's current desktop picture (or the user's chosen image). It reads the wallpaper through the public per-screen desktop-image API.
- The windows sit at window level ≈ −2147483602. That's a few levels **above Finder's desktop-icon windows** (≈ −2147483603) and the wallpaper, and below normal app windows. So the icons are covered, not removed.
- No preferences changed:
  - `com.apple.finder CreateDesktop` stayed absent.
  - `com.apple.WindowManager` (Stage Manager / "click wallpaper to reveal desktop") didn't change.
  - Finder and Dock kept their original PIDs and start times.
- The cover windows were removed on deactivate.
- It sets the windows to ignore mouse events, so clicks may pass through to the hidden icons underneath.

**How does it toggle DND/Focus on macOS 26? It doesn't, reliably.**
- On macOS 11 and earlier it writes the old Notification Center DND preference (ByHost) and posts the matching distributed notification.
- On macOS 12 and later:
  - It confirms Accessibility trust, then **posts a synthetic modifier-click (Option-click) at the top-right corner of the main screen**, where the menu bar clock is. On Monterey through Sonoma, Option-clicking the clock toggled DND.
  - It works out the current state by reading the private Focus database JSON files in `~/Library/DoNotDisturb/DB/` (assertion records and schedule).
- **What I observed here:**
  - PliimPRO recorded in its own prefs that it had turned DND on.
  - **Focus never came on.** Control Center showed no Focus indicator, and donotdisturbd logged events resolving as "disabled" right after activation.
  - It contacted the system's Accessibility warning service, which suggests it lacks Accessibility trust on this Mac.
  - The Option-click gesture is also unreliable on macOS 26: the main display here is in portrait and the menu bar's right edge is crowded. Either way, the DND step silently failed.

**How does it hide the Dock and the menu bar? It doesn't.**
- No Dock or menu-bar preference changed (`autohide`, `_HIHideMenuBar`, `AppleMenuBarVisibleInFullscreen`).
- No Dock restart, and no presentation-options call.
- (The Dock was already set to auto-hide on this Mac.)

**Hide apps**
- Hides every regular app through the public running-application API.
- On deactivate it **unhides every app**, including the six that were hidden before activation. **So it doesn't fully restore.**

**Mute speakers / mic**
- CoreAudio: sets the mute property on the default output (or input) device and listens for device changes. Not exercised at runtime because the setting was off.

**Processes spawned:** none. I watched for children of PliimPRO across a full on/off cycle and saw none: no `killall`, `defaults`, or `osascript`.

**Bug found:** a synthetic Accessibility press on its status button crashes it with a Swift runtime trap.

### PliimPRO system state: before → during → after

| Item | Before | During | After |
|---|---|---|---|
| Dock autohide | 1 | 1 | 1 |
| `_HIHideMenuBar` | 0 | 0 | 0 |
| `AppleMenuBarVisibleInFullscreen` | 0 | 0 | 0 |
| Finder `CreateDesktop` | absent | absent | absent |
| Desktop icons | visible | covered by three image windows | visible |
| Wallpaper (×3) | same image | unchanged (copied into the covers) | unchanged |
| Focus / DND | off | **off** (attempted; failed) | off |
| Volume (output / input / alert) | 44 / 7 / 51, not muted | same (mute setting off) | same |
| Hidden apps | 6 | all 36 regular apps | **0** (all unhidden) |
| Power assertions | none from PliimPRO | none | none |
| Child processes | — | none | none |

**Restoration:** after the tests I re-hid those six apps, quit both apps (neither was running when I started), deleted the temporary shortcut and PliimPRO's two test counters from its prefs, and moved the cursor back to the main screen. A final snapshot matched the baseline on every recorded item: Dock and menu-bar keys, Finder and WindowManager keys, all three wallpapers, volumes, Focus off, the same hidden-app set, and no Lungo or PliimPRO assertions. The paid DisplayBuddy and Display Buddy Free were never touched.

---

## 4. Private APIs used, and public alternatives

| App | Private / undocumented thing | Public alternative |
|---|---|---|
| PliimPRO | Embedded Apple-private **DFRFoundation** (Touch Bar control strip) | Public NSTouchBar inside the app's own windows only, or drop it (no current Mac has a Touch Bar). |
| PliimPRO | Reads the **private Focus DB JSON** files to detect DND | Read-only: the `INFocusStatusCenter` focus status (needs the Focus-status permission; reports whether a Focus is on). |
| PliimPRO | Toggles DND by **synthesizing an Option-click on the clock**. Undocumented UI behaviour; needs Accessibility. | Run a user-installed **Shortcuts** shortcut that uses the built-in "Set Focus" action (`/usr/bin/shortcuts run "<name>"`). Fully public and survives OS changes. |
| PliimPRO | Old NC prefs plus distributed notification (macOS ≤ 11) | n/a on macOS 26 |
| Neither | (For Dock / menu bar hiding if we add it) `_HIHideMenuBar` is undocumented | Dock: System Events' scriptable dock-preferences autohide property (Automation permission, no Dock restart), or the `autohide` default plus a Dock restart (heavier). Menu bar: no fully public system-wide switch. Ours could only be "auto-hide while our app is frontmost" via presentation options. |

Lungo uses no private APIs that I could find. Its IOKit assertion and power-source APIs are public and work inside the sandbox.

---

## 5. Recommendations for our Presence module

### 5.1 Keep-awake (from Lungo)

- **Do:** one `IOPMAssertionCreateWithName` with a clear name, released on stop.
  - Mode **Display + system** → PreventUserIdleDisplaySleep.
  - Mode **System only** → PreventUserIdleSystemSleep.
  - Hold exactly one assertion at a time. Swap it atomically when the mode changes.
- **Durations:** indefinite, presets, custom, and until a clock time. Drive them from a monotonic deadline, not repeated timers, so they survive sleep correctly.
- **Auto rules:** deactivate on battery (IOPS notification); pause on screen lock (screen-lock distributed notifications); optionally stop when thermal state is critical or Low Power Mode turns on.
- **Automation:** URL scheme, App Intents (on/off/get/remaining/extend) and a global hotkey.
- **Alternatives considered:**
  - Spawning `caffeinate`: rejected. It's an extra process, it's killed on crash, and it has no sandbox story.
  - `NSProcessInfo.beginActivity`: rejected. It's less explicit, and there's no display-only vs system-only choice that shows up in pmset.
- **Display Buddy tie-in:** an option to keep the external displays awake only while a chosen app is frontmost or a call is active. That's cheap to add on the same assertion.

### 5.2 Hide desktop icons (from PliimPRO, improved)

- **Do:** one borderless, non-activating window per `NSScreen`.
  - Level: one step above the desktop-icon level, so it covers the icons and stays below apps.
  - Collection behaviour: all Spaces, stationary, ignored by window cycling.
  - Content: that screen's current desktop image (public per-screen desktop-image API), drawn aspect-fill.
  - Rebuild on screen-parameter changes and Space changes. This matters with three portrait displays and hot-plugging.
- Decide deliberately whether clicks pass through. If they do, the user can still drag invisible icons. Our default: **don't** ignore mouse events, and let a click forward to "show desktop".
- **Alternatives considered:**
  - `defaults write com.apple.finder CreateDesktop false` plus a Finder restart: rejected. It's slow, visibly flashes, kills Finder windows, and needs a restart to undo.
  - macOS 14+'s own "hide desktop items" setting in `com.apple.WindowManager`: an undocumented key and not instant. Possible fallback only.

### 5.3 DND / Focus

- **Do:** ship a one-tap "Install Display Buddy Focus shortcuts" helper. It links to two signed Shortcuts (Focus on / Focus off) using the built-in Set Focus action. We run them with `shortcuts run` and read the state with `INFocusStatusCenter`.
- If the shortcut is missing, show a clear one-time setup prompt. Never fail silently, as PliimPRO does.
- **Alternatives considered:**
  - Option-click on the clock (PliimPRO's approach): rejected. It needs Accessibility, depends on menu bar layout, and **didn't work here on macOS 26**.
  - Private DND frameworks / donotdisturbd XPC: rejected. Private, and they break across releases.
  - Focus Filters (App Intents): these only let our app *react* to a Focus. Useful later, but they can't turn one on.

### 5.4 Hide other apps

- **Do:** **record which apps were already hidden** before hiding. On exit, unhide only the apps we hid, and re-activate the previously frontmost app.
- **Do:** honour an exclusion list: our own app, the presentation app, call apps.
- This fixes the PliimPRO restore bug I observed.

### 5.5 Dock / menu bar (neither app does this; nice extra)

- **Do (opt-in):**
  - Dock auto-hide through System Events' scriptable Dock preferences (Automation permission). Remember the prior value and restore it.
  - Menu bar: offer only "auto-hide while Display Buddy's presentation window is frontmost". There's no supported system-wide toggle.
- **Alternative:** writing the `autohide` default and restarting the Dock. Works without the Automation prompt, but there's a visible Dock restart. Fallback only.

### 5.6 Mute (from PliimPRO)

- **Do:** CoreAudio mute property on the default output device (and optionally the input), restored on exit.
- Optional: **lower alert volume to 0 and restore it**. The alert volume is the system beep, which a presentation should silence. Restoring via System Events volume settings works.
- Mic-mute hotkey with a small HUD and a menu bar state indicator is worth copying.

### 5.7 Robustness rules for the whole module

1. **Snapshot before, restore exactly after.** Persist the snapshot to disk so a crash or force-quit can be undone on the next launch.
2. **No child processes, no Finder or Dock restarts** by default.
3. **Never fail silently.** Show which sub-features succeeded, which failed, and why (for example, missing permission or missing shortcut).
4. **Multi-display first.** Per-screen covers, re-laid out on hot-plug and rotation.
5. **Survive menu bar overflow.** On macOS 26 both of these apps' icons were hidden on this Mac. Lungo detects that and warns. Ours should too, and every action should also be reachable via hotkey, URL scheme and Shortcuts.
6. **Status-item clicks:** don't assume a current mouse event exists in the click handler. AX presses (VoiceOver, automation) must work. That's the PliimPRO crash.

### 5.8 Extra features worth having

- From Lungo: icon styles for the active state, an "until time" duration, Shortcuts actions, iCloud settings sync, a menu-bar-hidden warning, deactivate on battery, pause on lock.
- From PliimPRO: custom presentation wallpaper, mic-mute hotkey with HUD, one combined "presentation mode" toggle.
- New ideas for Display Buddy:
  - A presentation profile that also sets brightness / colour temperature on the three external displays (e.g. full brightness, neutral 6500 K) and restores it afterwards.
  - Automatically enter presentation mode when a screen-share or Keynote/PowerPoint presenter window appears.
  - Keep the displays awake only during that time.

---

## 6. What I could not do

- **Open PliimPRO's status menu or preferences window.**
  - Its icon is in the menu bar overflow, off-screen.
  - Synthetic clicks can't reach status items, which macOS 26 hosts inside Control Center.
  - An AX press crashes it, and reopening the app doesn't show a window.
  - Its options above come from its stored preference keys, symbols and the toggle I observed, not from looking at its UI.
- **Lungo's main menu contents:** for the same overflow reason, the menu couldn't be shown or read. Its Settings window (General, Shortcuts, Advanced) was fully mapped through Accessibility.
- **Screenshots of either app:** the shell lacks Screen Recording permission. REA's UI observer refused the windows.
- **Reading the Focus database directly:** blocked by TCC. Focus state came from Control Center's Focus indicator and donotdisturbd logs.
- **Runtime tests of PliimPRO's mute-speaker, mic-mute and custom-wallpaper options:** they were off in the user's settings, and I didn't change them. Their mechanisms come from static inspection only.
- **Lungo "allow sleep while locked":** not tested at runtime (it would need the screen locked). The mechanism comes from static inspection.
- **Reading Lungo's sandboxed preferences file directly:** reading inside its container stalls under App Data protection. Settings were read through its UI instead, and every setting I toggled was set back.
- **REA process capture** ran but reported a cleanup error caused by the long-lived apps. I used `ps` polling for the final process observations.
- **Which Chrome process was hidden at baseline:** two Chrome processes existed and the baseline recorded only names. I re-hid the most likely one; the final hidden-app list matches the baseline by name.

---

## 7. Phase 3: our build compared with the originals

Same machine and the same before/during/after snapshot script as Phase 0.

| What changes | Lungo | PliimPRO | Display Buddy Presence |
|---|---|---|---|
| Keep-awake mechanism | one IOKit assertion: display-sleep by default, system-sleep when the display may sleep | none of its own | one IOKit assertion: PreventUserIdleDisplaySleep ("Keep display on") or PreventUserIdleSystemSleep ("Display may sleep"); swapped atomically when the mode changes |
| Timed sessions | assertion released at expiry | n/a | assertion released at exactly 60 s for a 1-minute session, followed by a notification |
| Desktop icons | n/a | one image window per screen at desktop-icon level + 1 | same level, one window per screen, rebuilt on display changes; clicks blocked |
| Dock / menu bar | n/a | unchanged | auto-hide via System Events, previous values restored (needs Automation permission) |
| Do Not Disturb | n/a | Option-click on the clock; failed silently on macOS 26 | user's Set Focus shortcuts; a missing shortcut shows a message and setup steps |
| Wallpaper | n/a | unchanged (copied into the cover) | optional neutral colour, restored per screen by display UUID |
| Hidden apps after turning off | n/a | **all** apps unhidden | only the apps it hid; apps hidden beforehand stay hidden; the previous front app is re-activated |
| Child processes | none | none | only `/usr/bin/shortcuts` (for Focus) |
| Crash / force-quit | assertion dies with the process | — | assertion and covers die with the process; other changes are restored automatically at next launch from the saved state file |
| Entitlements / usage strings | sandbox + network | microphone; hardened runtime | none (ad-hoc signed, not sandboxed); adds only an Apple Events usage description |

**Not compared with REA `compare_process_captures`.** The Phase 0 REA captures of the originals never produced evidence (REA cleanup failed on the long-lived apps), so there was nothing to compare against. The comparison above uses the same text snapshots for all three apps.
