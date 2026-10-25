# How to install Display Buddy (step by step)

You don't need any technical tools. It takes about 3 minutes.

## 1. Download
1. Open the **Releases** page of this project on GitHub (the "latest" release).
2. Click **DisplayBuddy.zip** to download it.
3. Open your **Downloads** folder and double-click the zip. You'll get **Display Buddy Free.app**.
4. Drag **Display Buddy Free.app** into your **Applications** folder.

## 2. Open it the first time
The app is free and not sold through Apple, so macOS shows a warning the first time.
1. In **Applications**, double-click **Display Buddy Free**. macOS says it "cannot be opened". Click **Done** (or OK).
2. Open **System Settings → Privacy & Security**. Scroll down: you'll see *"Display Buddy Free was blocked"*. Click **Open Anyway** and enter your Mac password.
3. Click **Open** in the next window.

You'll now see the Display Buddy icon in the menu bar (top right) and in the Dock.

## 3. Turn on the keyboard brightness keys
macOS asks for **Accessibility** permission (this is what lets an app see key presses).
1. When asked, click **Open System Settings**.
2. Switch **Display Buddy Free** on in the list.
3. Press the brightness keys (F1 / F2) on your Apple keyboard. All your monitors change together, and a brightness bubble appears.

Tip: hold **Option + Shift** while pressing the keys for very small steps.

## 4. Using it
Click the menu bar icon:
- **Brightness** moves all monitors together. Going left past 0 enters **sub-zero** (darker than your monitors normally go).
- **Monitors → Match**: if one monitor looks brighter than the others, nudge its Match slider until they look the same. The app remembers this per monitor, so home and work monitors each keep their own setting.
- **Link button**: unlink a monitor to control it separately.
- **Colour temperature**: *Sun* warms the screens at sunset and cools them at sunrise. *Manual* lets you pick a fixed warmth.
- **Dock icon / Open at login** checkboxes at the bottom.

If you use Bartender or Ice, the Display Buddy icon appears in their list like any other menu bar app.

## 5. Keep Awake and Presentation mode (optional)
Tick **Keep Awake & Presentation mode** at the bottom of the menu. The menu gets three tabs: **Brightness**, **Keep Awake** and **Presentation**.
- **Keep Awake** keeps your Mac awake for the time you pick (⌃⌥K). Choose *Keep display on*, or *Display may sleep* to keep only the Mac awake. You can also list apps (e.g. Zoom, Keynote) that keep the Mac awake while they run. A small dot on the menu bar icon shows it is on.
- **Presentation** (⌃⌥P) hides desktop icons, turns on Do Not Disturb, auto-hides the Dock and menu bar and keeps the screens on. Each option can be switched on or off in the tab. Turning presentation mode off puts everything back.
- **Share area** (Presentation tab) puts an orange landscape frame on a vertical screen. In Teams, Zoom, Slack, Discord, Meet or Whereby choose *Share → Window → Display Buddy — Shared area* to show only what is inside the frame. The first time, allow Display Buddy Free under **System Settings → Privacy & Security → Screen & System Audio Recording**.

The first time presentation mode hides the Dock, macOS asks whether Display Buddy Free may control **System Events**. Click **OK**. If you clicked *Don't Allow*, open **System Settings → Privacy & Security → Automation** and switch on System Events under Display Buddy Free.

**Do Not Disturb needs two shortcuts** (macOS doesn't let apps switch Focus directly):
1. Open the **Shortcuts** app and click **+**.
2. Add the **Set Focus** action, choose **Do Not Disturb**, **Turn On**, and name the shortcut **Display Buddy Focus On**.
3. Make a second shortcut the same way with **Turn Off**, named **Display Buddy Focus Off**.
4. In Display Buddy's Presence settings, click **Check shortcuts**.

## After an update
When you install a newer version, macOS may forget the Accessibility permission. Open **System Settings → Privacy & Security → Accessibility**, remove Display Buddy Free with the **−** button, and switch it on again. It may also ask again for **Automation** (System Events) the next time presentation mode runs.

## If a monitor shows "software only"
That monitor doesn't accept brightness commands through the cable (common with DisplayLink docks and some TVs). Display Buddy still dims it in software, but it can't change the real backlight.

## If you also have the paid Display Buddy (Setapp)
Quit it before using this app (click its menu bar icon → Quit), otherwise both apps fight over the monitors and the brightness keys. This free app is called **Display Buddy Free** so you can tell them apart.
