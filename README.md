# Device Shots

A tiny macOS menu-bar app that captures screenshots from connected iOS and
Android devices straight to the clipboard. No streaming, no windows... just a
camera icon in the menu bar.

Great for pasting UI screenshots in Figma for QA, or referencing screenshots and sharing them in chats. 
Much faster than native screenshot flows.

## Install

Download the latest `DeviceShots-vX.Y.zip` from
[Releases](https://github.com/RaphyRaph/DeviceShots/releases), unzip, and
drag Device Shots.app to /Applications. The app is notarized by Apple.

Requirements:

- **Xcode** (for iOS devices and simulators — the app uses its `devicectl`
  and `simctl` tools)
- **adb** for Android devices: `brew install android-platform-tools`

## Usage

Click the camera-viewfinder icon in the menu bar. A native macOS menu lists
every detected device; select one to copy its current screen to the clipboard.
A brief "Capturing…" HUD appears at the top of the screen while the capture
runs, then a "Pop" sound confirms the copy. The next menu opening shows the
result beside that device. The menu also includes refresh, setup guidance,
Settings, and Quit.

Detected devices:

- **Android** — anything visible to `adb devices` (USB or Wi-Fi debugging)
- **iOS (physical)** — devices paired with Xcode, reachable via USB or Wi-Fi
  (uses `xcrun devicectl`; requires Developer Mode enabled on the device)
- **iOS simulators** — any booted simulator (uses `xcrun simctl`)

The device menu refreshes each time it opens and can also be refreshed manually.
Multiple devices can be listed and captured independently — but note the
clipboard only holds one image at a time. Devices use their discovery order;
manual reordering is not available.

## Settings

Open via **Settings…** in the menu. Two sections:

- **Capture** — what a capture produces:
  - *Copy to clipboard*: Image only, File only, or Image and file (file mode
    puts an image file on the pasteboard, e.g. for pasting into Finder or Slack)
  - *Android format*: JPEG (faster, default) or PNG (lossless)
  - *Save a copy to folder* with a chooseable destination
  - *Include device name in filename* (e.g. `iPhone 15 Pro 2026-07-08 at 14.30.52.png`)
  - *Play sound after capture*
- **Shortcuts** — six fixed slots, each with a **Capture** and a **Capture &
  Paste** hotkey. Shortcuts belong to the slot; devices remember theirs:
  - A newly connected physical device takes the first empty slot (simulators
    are only slotted by hand).
  - A disconnected device keeps its slot and shows as Disconnected.
  - Drag a device onto another slot to move it (occupied slots swap), or
    click × to free a slot. A device cleared while connected isn't
    re-assigned until it reconnects.
  - The menu lists connected devices in slot order with their shortcut.
  Click "Record" and type a combination; Esc cancels, Delete clears.
  Capture works system-wide without opening the menu (Carbon
  `RegisterEventHotKey`). Capture & Paste also posts ⌘V into the frontmost app
  and prompts for Accessibility permission on first use.

## Building

```sh
./build.sh
open "Device Shots.app"
```

Requires Xcode (for `devicectl`/`simctl` and the Swift toolchain). `adb` is
looked up in the usual Homebrew / Android SDK locations plus `$ANDROID_HOME`.

## Notes

- Physical iOS devices appear when CoreDevice reports a live tunnel, or when
  the phone/tablet is plugged in over USB (`transportType: wired`) even if the
  developer tunnel still says disconnected. Wi‑Fi debugging still needs an
  active CoreDevice tunnel.
- To launch at login: System Settings → General → Login Items → add
  Device Shots.app.
