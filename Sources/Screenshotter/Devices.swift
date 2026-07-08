import Foundation

struct CaptureError: Error {
    let message: String
}

enum DeviceKind: String {
    case android = "Android"
    case ios = "iOS"
    case simulator = "Simulator"
}

struct Device: Identifiable, Equatable {
    let id: String          // adb serial, devicectl identifier, or simulator UDID
    let name: String
    let detail: String      // model / OS info shown as subtitle
    let kind: DeviceKind
    let available: Bool     // false when paired but not reachable (no tunnel)
    var isTablet = false

    var icon: String { isTablet ? "apps.ipad" : "apps.iphone" }
}

struct CommandResult {
    var stdout = Data()
    var stderr = Data()
    var status: Int32 = -1
    var launchError: String?

    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    var succeeded: Bool { launchError == nil && status == 0 }
    var errorSummary: String {
        if let launchError { return launchError }
        let err = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "exit code \(status)" : String(err.suffix(300))
    }
}

func runCommand(_ executable: String, _ arguments: [String]) async -> CommandResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(launchError: error.localizedDescription))
                return
            }
            let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus))
        }
    }
}

let xcrunPath = "/usr/bin/xcrun"

/// devicectl/simctl ship with Xcode, not macOS or the Command Line Tools.
let hasXcodeTools: Bool = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: xcrunPath)
    process.arguments = ["--find", "devicectl"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}()

/// GUI apps don't inherit the shell PATH, so look for adb in the usual spots.
let adbPath: String? = {
    var candidates = [
        "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
    ]
    for envVar in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let root = ProcessInfo.processInfo.environment[envVar] {
            candidates.insert(root + "/platform-tools/adb", at: 0)
        }
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}()

enum DeviceDiscovery {

    static func allDevices() async -> [Device] {
        async let android = androidDevices()
        async let ios = iosPhysicalDevices()
        async let sims = bootedSimulators()
        return await android + ios + sims
    }

    // MARK: Android via adb

    static func androidDevices() async -> [Device] {
        guard let adbPath else { return [] }
        let result = await runCommand(adbPath, ["devices", "-l"])
        guard result.succeeded else { return [] }
        var devices: [Device] = []
        for line in result.stdoutText.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2 else { continue }
            let serial = fields[0]
            let state = fields[1]
            guard state == "device" || state == "unauthorized" || state == "offline" else { continue }
            var model = ""
            for field in fields.dropFirst(2) where field.hasPrefix("model:") {
                model = String(field.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ")
            }
            let name = model.isEmpty ? serial : model
            let detail = state == "device" ? serial : "\(serial) — \(state)"
            let isTablet = ["tab", "pad", "tablet"].contains { name.lowercased().contains($0) }
            devices.append(Device(id: serial, name: name, detail: detail,
                                  kind: .android, available: state == "device",
                                  isTablet: isTablet))
        }
        return devices
    }

    // MARK: Physical iOS devices via devicectl

    static func iosPhysicalDevices() async -> [Device] {
        guard hasXcodeTools else { return [] }
        let jsonPath = NSTemporaryDirectory() + "screenshotter-devicectl-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let result = await runCommand(xcrunPath, ["devicectl", "list", "devices", "--quiet", "--json-output", jsonPath, "--timeout", "10"])
        guard result.succeeded,
              let data = FileManager.default.contents(atPath: jsonPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultDict = root["result"] as? [String: Any],
              let deviceList = resultDict["devices"] as? [[String: Any]]
        else { return [] }

        var devices: [Device] = []
        for entry in deviceList {
            let hardware = entry["hardwareProperties"] as? [String: Any] ?? [:]
            guard (hardware["reality"] as? String) == "physical",
                  let identifier = entry["identifier"] as? String else { continue }
            let props = entry["deviceProperties"] as? [String: Any] ?? [:]
            let connection = entry["connectionProperties"] as? [String: Any] ?? [:]
            // Xcode remembers previously paired devices; only list ones that are
            // actually reachable right now (USB or Wi-Fi tunnel).
            let tunnelState = connection["tunnelState"] as? String ?? "unavailable"
            guard tunnelState != "unavailable" else { continue }
            let name = props["name"] as? String ?? identifier
            let marketing = hardware["marketingName"] as? String ?? "iOS device"
            let osVersion = props["osVersionNumber"] as? String ?? ""
            let detail = osVersion.isEmpty ? marketing : "\(marketing) · iOS \(osVersion)"
            devices.append(Device(id: identifier, name: name, detail: detail,
                                  kind: .ios, available: true,
                                  isTablet: (hardware["deviceType"] as? String) == "iPad"))
        }
        return devices
    }

    // MARK: Booted simulators via simctl

    static func bootedSimulators() async -> [Device] {
        guard hasXcodeTools else { return [] }
        let result = await runCommand(xcrunPath, ["simctl", "list", "devices", "booted", "-j"])
        guard result.succeeded,
              let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]]
        else { return [] }

        var devices: [Device] = []
        for (runtime, sims) in runtimes {
            // e.g. com.apple.CoreSimulator.SimRuntime.iOS-26-0 -> iOS 26.0
            let parts = runtime
                .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                .split(separator: "-")
            let osName = parts.isEmpty ? runtime
                : parts.first! + " " + parts.dropFirst().joined(separator: ".")
            for sim in sims {
                guard let udid = sim["udid"] as? String,
                      let name = sim["name"] as? String,
                      (sim["state"] as? String) == "Booted" else { continue }
                devices.append(Device(id: udid, name: name, detail: osName,
                                      kind: .simulator, available: true,
                                      isTablet: name.localizedCaseInsensitiveContains("iPad")))
            }
        }
        return devices.sorted { $0.name < $1.name }
    }

    // MARK: Screenshot capture — returns PNG data

    static func captureScreenshot(of device: Device) async -> Result<Data, CaptureError> {
        switch device.kind {
        case .android:
            guard let adbPath else { return .failure(CaptureError(message: "adb not found")) }
            let result = await runCommand(adbPath, ["-s", device.id, "exec-out", "screencap", "-p"])
            guard result.succeeded, isPNG(result.stdout) else {
                return .failure(CaptureError(message: result.succeeded ? "did not receive a PNG from adb" : result.errorSummary))
            }
            return .success(result.stdout)

        case .ios:
            return await captureToTempFile { path in
                await runCommand(xcrunPath, ["devicectl", "device", "capture", "screenshot",
                                             "--device", device.id, "--destination", path,
                                             "--quiet", "--timeout", "30"])
            }

        case .simulator:
            return await captureToTempFile { path in
                await runCommand(xcrunPath, ["simctl", "io", device.id, "screenshot", path])
            }
        }
    }

    private static func captureToTempFile(_ run: (String) async -> CommandResult) async -> Result<Data, CaptureError> {
        let path = NSTemporaryDirectory() + "screenshotter-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = await run(path)
        guard result.succeeded else { return .failure(CaptureError(message: friendlyError(result))) }
        guard let data = FileManager.default.contents(atPath: path), isPNG(data) else {
            return .failure(CaptureError(message: "screenshot file was not written"))
        }
        return .success(data)
    }

    /// devicectl dumps a verbose multi-level error tree to stderr; pull out the
    /// actionable message instead of showing the raw tail.
    private static func friendlyError(_ result: CommandResult) -> String {
        let text = result.stderrText + "\n" + result.stdoutText
        let lower = text.lowercased()

        if lower.contains("developer mode is not enabled") {
            return "Developer Mode is off. On the device: Settings → Privacy & Security → Developer Mode, then restart it."
        }
        if lower.contains("passcode protected") || lower.contains("device is locked") {
            return "The device is locked — unlock it and try again."
        }
        if lower.contains("tunnel") && lower.contains("connect") {
            return "Lost connection to the device — replug it or check Wi‑Fi."
        }
        // First "ERROR:" line is devicectl's top-level summary.
        if let errorLine = text.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("ERROR:") }) {
            return String(errorLine.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return result.errorSummary
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count > 8 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
    }
}
