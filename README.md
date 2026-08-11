# Device Shots

A tiny macOS menu-bar app that captures screenshots from connected iOS and
Android devices straight to the clipboard. No streaming, no windows — just a
camera icon in the menu bar.

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
every detected device; select one to copy its current screen to the clipboard
as PNG. A "Pop" sound confirms the copy, and the next menu opening shows the
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
    puts a PNG file on the pasteboard, e.g. for pasting into Finder or Slack)
  - *Save a copy to folder* with a chooseable destination
  - *Include device name in filename* (e.g. `iPhone 15 Pro 2026-07-08 at 14.30.52.png`)
  - *Play sound after capture*
- **Shortcuts** — global hotkeys for **Capture Device 1…6**. Each shortcut
  captures the device at that discovery position in the menu (top to bottom);
  the assigned shortcut is shown next to the device. Click "Record shortcut"
  and type a combination; Esc cancels, Delete clears. Hotkeys work
  system-wide without opening the panel (Carbon `RegisterEventHotKey`, no
  accessibility permission needed).

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
