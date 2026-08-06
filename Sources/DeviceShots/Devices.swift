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

/// Stable user ordering for device rows and the shortcut positions that refer
/// to them. Newly discovered devices remain in their discovery order after
/// explicitly ordered devices.
enum DeviceOrder {
    static func applying(_ preferredIDs: [String], to discovered: [Device]) -> [Device] {
        let positions = Dictionary(uniqueKeysWithValues: preferredIDs.enumerated().map { ($1, $0) })
        return discovered.enumerated().sorted { lhs, rhs in
            let lhsPosition = positions[lhs.element.id] ?? Int.max
            let rhsPosition = positions[rhs.element.id] ?? Int.max
            return lhsPosition == rhsPosition ? lhs.offset < rhs.offset : lhsPosition < rhsPosition
        }.map(\.element)
    }

    static func moving(_ devices: [Device], id: String, before targetID: String) -> [Device] {
        guard id != targetID,
              let sourceIndex = devices.firstIndex(where: { $0.id == id })
        else { return devices }

        var reordered = devices
        let device = reordered.remove(at: sourceIndex)
        guard let targetIndex = reordered.firstIndex(where: { $0.id == targetID }) else { return devices }
        reordered.insert(device, at: targetIndex)
        return reordered
    }

    static func moving(_ devices: [Device], id: String, to destination: Int) -> [Device] {
        guard let sourceIndex = devices.firstIndex(where: { $0.id == id }) else { return devices }
        var reordered = devices
        let device = reordered.remove(at: sourceIndex)
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        reordered.insert(device, at: min(max(adjustedDestination, 0), reordered.count))
        return reordered
    }

    static func moving(_ devices: [Device], from source: IndexSet, to destination: Int) -> [Device] {
        let moving = source.compactMap { devices.indices.contains($0) ? devices[$0] : nil }
        guard !moving.isEmpty else { return devices }

        var reordered = devices
        for index in source.sorted(by: >) where reordered.indices.contains(index) {
            reordered.remove(at: index)
        }
        let adjustment = source.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - adjustment, 0), reordered.count)
        reordered.insert(contentsOf: moving, at: insertionIndex)
        return reordered
    }
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

/// Tracks command-line tools started by the app so quitting does not leave a
/// device discovery or screenshot process running after Device Shots exits.
final class CommandProcessRegistry: @unchecked Sendable {
    static let shared = CommandProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]
    private var isShuttingDown = false

    /// Returns false once app shutdown has begun. A process registered during
    /// that small race window is terminated immediately.
    func register(_ process: Process) -> Bool {
        lock.lock()
        let shouldRun = !isShuttingDown
        if shouldRun {
            processes[ObjectIdentifier(process)] = process
        }
        lock.unlock()

        if !shouldRun { process.terminate() }
        return shouldRun
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        isShuttingDown = true
        let active = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for process in active where process.isRunning {
            process.terminate()
        }
    }
}

/// `adb` leaves its server running after a client exits. We only stop that
/// server if this app saw itself start it, so we never disrupt an Android
/// development session that was already using the shared server.
final class ADBServerLifecycle: @unchecked Sendable {
    static let shared = ADBServerLifecycle()

    private let lock = NSLock()
    private var startedByDeviceShots = false

    func recordStartup(from result: CommandResult) {
        guard result.succeeded,
              result.stderrText.localizedCaseInsensitiveContains("daemon started successfully")
        else { return }

        lock.lock()
        startedByDeviceShots = true
        lock.unlock()
    }

    func stopIfOwned(_ executable: String?) {
        lock.lock()
        let shouldStop = startedByDeviceShots
        startedByDeviceShots = false
        lock.unlock()

        guard shouldStop, let executable else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["kill-server"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The app is already terminating; there is nothing useful to show.
        }
    }
}

func runCommand(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async -> CommandResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
            }
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
            guard CommandProcessRegistry.shared.register(process) else {
                continuation.resume(returning: CommandResult(launchError: "Device Shots is quitting"))
                return
            }
            defer { CommandProcessRegistry.shared.unregister(process) }

            // A device tool can emit a large diagnostic while it is still
            // running. Drain both pipes concurrently so neither pipe can fill
            // and block the child before it closes the other stream.
            let reads = DispatchGroup()
            let outputLock = NSLock()
            var stdout = Data()
            var stderr = Data()
            reads.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                outputLock.lock()
                stdout = data
                outputLock.unlock()
                reads.leave()
            }
            reads.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                outputLock.lock()
                stderr = data
                outputLock.unlock()
                reads.leave()
            }
            process.waitUntilExit()
            reads.wait()
            continuation.resume(returning: CommandResult(stdout: stdout, stderr: stderr, status: process.terminationStatus))
        }
    }
}

let xcrunPath = "/usr/bin/xcrun"

/// The app is commonly launched from Finder, where it inherits the system
/// developer directory. That directory can point at Command Line Tools even
/// when a full Xcode is installed, and Command Line Tools does not include
/// devicectl. Resolve an installed Xcode directly so iPhone discovery does not
/// depend on the user's global `xcode-select` setting.
let xcodeDeveloperDirectory: String? = {
    let fileManager = FileManager.default
    var candidates: [String] = []
    if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
        candidates.append(configured)
    }
    candidates += [
        "/Applications/Xcode.app/Contents/Developer",
        "/Applications/Xcode-beta.app/Contents/Developer",
    ]
    if let applications = try? fileManager.contentsOfDirectory(atPath: "/Applications") {
        candidates += applications
            .filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }
            .map { "/Applications/\($0)/Contents/Developer" }
    }

    var seen = Set<String>()
    return candidates.first { directory in
        seen.insert(directory).inserted
            && fileManager.isExecutableFile(atPath: directory + "/usr/bin/devicectl")
    }
}()

/// devicectl/simctl ship with Xcode, not macOS or the Command Line Tools.
let hasXcodeTools = xcodeDeveloperDirectory != nil

func runXcodeCommand(_ arguments: [String]) async -> CommandResult {
    guard let xcodeDeveloperDirectory else {
        return CommandResult(launchError: "Xcode with devicectl was not found")
    }
    return await runCommand(xcrunPath, arguments,
                            environment: ["DEVELOPER_DIR": xcodeDeveloperDirectory])
}

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

func runADBCommand(_ arguments: [String]) async -> CommandResult {
    guard let adbPath else {
        return CommandResult(launchError: "adb not found")
    }
    let result = await runCommand(adbPath, arguments)
    ADBServerLifecycle.shared.recordStartup(from: result)
    return result
}

enum DeviceDiscovery {

    static func allDevices() async -> [Device] {
        async let android = androidDevices()
        async let ios = iosPhysicalDevices()
        async let sims = bootedSimulators()
        return await android + ios + sims
    }

    // MARK: Android via adb

    static func androidDevices() async -> [Device] {
        guard adbPath != nil else { return [] }
        let result = await runADBCommand(["devices", "-l"])
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
            let versionResult = state == "device"
                ? await runADBCommand(["-s", serial, "shell", "getprop", "ro.build.version.release"])
                : CommandResult()
            let version = versionResult.succeeded
                ? versionResult.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            let detail = version.isEmpty ? "Android" : "Android \(displayOSVersion(version))"
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
        let jsonPath = NSTemporaryDirectory() + "deviceshots-devicectl-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let result = await runXcodeCommand(["devicectl", "list", "devices", "--quiet", "--json-output", jsonPath, "--timeout", "10"])
        guard result.succeeded, let data = FileManager.default.contents(atPath: jsonPath) else { return [] }
        return parseIOSPhysicalDevices(from: data)
    }

    /// Kept separate from the command invocation so CoreDevice's evolving JSON
    /// can be covered by a fixture without a physical device attached.
    static func parseIOSPhysicalDevices(from data: Data) -> [Device] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
            // Xcode remembers previously paired devices; only list ones with
            // a live USB or Wi-Fi tunnel right now.
            let tunnelState = connection["tunnelState"] as? String ?? "unavailable"
            guard tunnelState == "connected" else { continue }
            let name = props["name"] as? String ?? identifier
            let marketing = hardware["marketingName"] as? String ?? "iOS device"
            let osVersion = props["osVersionNumber"] as? String ?? ""
            let detail = osVersion.isEmpty ? marketing : "\(marketing) · iOS \(displayOSVersion(osVersion))"
            devices.append(Device(id: identifier, name: name, detail: detail,
                                  kind: .ios, available: true,
                                  isTablet: (hardware["deviceType"] as? String) == "iPad"))
        }
        return devices
    }

    // MARK: Booted simulators via simctl

    static func bootedSimulators() async -> [Device] {
        guard hasXcodeTools else { return [] }
        let result = await runXcodeCommand(["simctl", "list", "devices", "booted", "-j"])
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
            guard adbPath != nil else { return .failure(CaptureError(message: "adb not found")) }
            let result = await runADBCommand(["-s", device.id, "exec-out", "screencap", "-p"])
            guard result.succeeded, isPNG(result.stdout) else {
                return .failure(CaptureError(message: result.succeeded ? "did not receive a PNG from adb" : result.errorSummary))
            }
            return .success(result.stdout)

        case .ios:
            return await captureToTempFile { path in
                await runXcodeCommand(["devicectl", "device", "capture", "screenshot",
                                             "--device", device.id, "--destination", path,
                                             "--quiet", "--timeout", "30"])
            }

        case .simulator:
            return await captureToTempFile { path in
                await runXcodeCommand(["simctl", "io", device.id, "screenshot", path])
            }
        }
    }

    private static func captureToTempFile(_ run: (String) async -> CommandResult) async -> Result<Data, CaptureError> {
        let path = NSTemporaryDirectory() + "deviceshots-\(UUID().uuidString).png"
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

private func displayOSVersion(_ version: String) -> String {
    var components = version.split(separator: ".", omittingEmptySubsequences: false)
    while components.last == "0" && components.count > 1 {
        components.removeLast()
    }
    return components.joined(separator: ".")
}
