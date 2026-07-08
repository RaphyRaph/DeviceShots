# Screenshotter

A tiny macOS menu-bar app that captures screenshots from connected iOS and
Android devices straight to the clipboard. No streaming, no windows — just a
camera icon in the menu bar.

## Install

Download the latest `Screenshotter-vX.Y.zip` from
[Releases](https://github.com/RaphyRaph/Screenshotter/releases), unzip, and
drag Screenshotter.app to /Applications. The app is notarized by Apple.

Requirements:

- **Xcode** (for iOS devices and simulators — the app uses its `devicectl`
  and `simctl` tools)
- **adb** for Android devices: `brew install android-platform-tools`

## Usage

Click the camera-viewfinder icon in the menu bar. Every detected device is
listed; click the camera button next to one to copy its current screen to the
clipboard as PNG. A "Pop" sound and a green checkmark confirm the copy.

Detected devices:

- **Android** — anything visible to `adb devices` (USB or Wi-Fi debugging)
- **iOS (physical)** — devices paired with Xcode, reachable via USB or Wi-Fi
  (uses `xcrun devicectl`; requires Developer Mode enabled on the device)
- **iOS simulators** — any booted simulator (uses `xcrun simctl`)

The device list refreshes automatically every few seconds while the panel is
open. Multiple devices can be listed and captured independently — but note the
clipboard only holds one image at a time.

## Settings

Open via the gear icon in the panel footer. Two sections:

- **Capture** — what a capture produces:
  - *Copy to clipboard*: Image only, File only, or Image and file (file mode
    puts a PNG file on the pasteboard, e.g. for pasting into Finder or Slack)
  - *Save a copy to folder* with a chooseable destination
  - *Include device name in filename* (e.g. `iPhone 15 Pro 2026-07-08 at 14.30.52.png`)
  - *Play sound after capture*
- **Shortcuts** — global hotkeys for **Capture Device 1…6**. Each shortcut
  captures the device at that position in the menu list (top to bottom); the
  assigned shortcut is shown next to the device row. Click "Record shortcut"
  and type a combination; Esc cancels, Delete clears. Hotkeys work
  system-wide without opening the panel (Carbon `RegisterEventHotKey`, no
  accessibility permission needed).

## Building

```sh
./build.sh
open Screenshotter.app
```

Requires Xcode (for `devicectl`/`simctl` and the Swift toolchain). `adb` is
looked up in the usual Homebrew / Android SDK locations plus `$ANDROID_HOME`.

## Notes

- Physical iOS devices show "not connected" (button disabled) when no
  CoreDevice tunnel is available — plug in via USB or ensure Wi-Fi debugging
  is active in Xcode.
- To launch at login: System Settings → General → Login Items → add
  Screenshotter.app.
