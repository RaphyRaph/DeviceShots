import Foundation

/// Runtime toggles for latency A/B runs. Driven by `DEVICESHOTS_OPT_*` env vars
/// so `scripts/compare-capture-latency.sh` can isolate each change.
enum LatencyOpts {
    /// When true, hotkeys rediscover devices before every capture (legacy).
    static var forceHotkeyRefresh: Bool {
        ProcessInfo.processInfo.environment["DEVICESHOTS_OPT_HOTKEY_REFRESH"] == "1"
    }

    /// Clipboard TIFF handling for image mode.
    enum TIFFMode: String {
        case sync      // encode TIFF before deliver returns (legacy)
        case deferred  // PNG first, TIFF after yield (current)
        case skip      // PNG only
    }

    static var tiffMode: TIFFMode {
        let raw = ProcessInfo.processInfo.environment["DEVICESHOTS_OPT_TIFF"] ?? "deferred"
        // Accept the older "defer" spelling used in scripts.
        if raw == "defer" { return .deferred }
        return TIFFMode(rawValue: raw) ?? .deferred
    }

    /// Parallelize per-device `adb getprop` during Android discovery.
    /// Default on: helps multi-device refresh; single-device cost is negligible.
    static var parallelGetprop: Bool {
        ProcessInfo.processInfo.environment["DEVICESHOTS_OPT_PARALLEL_GETPROP"] != "0"
    }

    /// Call `devicectl` / `simctl` binaries directly instead of via `xcrun`.
    /// Default on: one fewer process hop on Apple capture/discovery.
    static var directXcodeTools: Bool {
        ProcessInfo.processInfo.environment["DEVICESHOTS_OPT_DIRECT_XCODE"] != "0"
    }

    /// Timeout seconds for `devicectl list devices` during discovery.
    static var discoveryTimeoutSeconds: Int {
        Int(ProcessInfo.processInfo.environment["DEVICESHOTS_OPT_DISCOVERY_TIMEOUT"] ?? "10") ?? 10
    }

    static var summary: String {
        [
            "hotkey_refresh=\(forceHotkeyRefresh ? 1 : 0)",
            "tiff=\(tiffMode.rawValue)",
            "parallel_getprop=\(parallelGetprop ? 1 : 0)",
            "direct_xcode=\(directXcodeTools ? 1 : 0)",
            "discovery_timeout=\(discoveryTimeoutSeconds)",
        ].joined(separator: " ")
    }
}
