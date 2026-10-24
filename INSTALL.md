# How to install Display Buddy (step by step)

You don't need any technical tools. It takes about 3 minutes.

## 1. Download
1. Open the **Releases** page of this project on GitHub (the "latest" release).
2. Click **DisplayBuddy.zip** to download it.
3. Open your **Downloads** folder and double-click the zip. You'll get **Display Buddy.app**.
4. Drag **Display Buddy.app** into your **Applications** folder.

## 2. Open it the first time
The app is free and not sold through Apple, so macOS shows a warning the first time.
1. In **Applications**, double-click **Display Buddy**. macOS says it "cannot be opened". Click **Done** (or OK).
2. Open **System Settings → Privacy & Security**. Scroll down: you'll see *"Display Buddy was blocked"*. Click **Open Anyway** and enter your Mac password.
3. Click **Open** in the next window.

You'll now see the Display Buddy icon in the menu bar (top right) and in the Dock.

## 3. Turn on the keyboard brightness keys
macOS asks for **Accessibility** permission (this is what lets an app see key presses).
1. When asked, click **Open System Settings**.
2. Switch **Display Buddy** on in the list.
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

## After an update
When you install a newer version, macOS may forget the Accessibility permission. Open **System Settings → Privacy & Security → Accessibility**, remove Display Buddy with the **−** button, and switch it on again.

## If a monitor shows "software only"
That monitor doesn't accept brightness commands through the cable (common with DisplayLink docks and some TVs). Display Buddy still dims it in software, but it can't change the real backlight.
