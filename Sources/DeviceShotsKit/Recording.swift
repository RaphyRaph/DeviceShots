import AppKit
import Combine
import Foundation

extension Device {
    /// `devicectl` has no screen-recording command, so physical iOS devices
    /// can't be recorded; simulators (simctl) and Android (screenrecord) can.
    var canRecordVideo: Bool { kind != .ios }
}

/// One in-flight recording. The recording tool runs for as long as the
/// recording does; its exit (user stop, Android's time limit, or a failure)
/// is what finalizes the session.
private final class RecordingSession {
    let device: Device
    let process = Process()
    let startedAt = Date()
    let localURL: URL
    let logURL: URL
    /// Android records on the device first and is pulled afterwards.
    let remotePath: String?
    var stopRequested = false

    init(device: Device, localURL: URL) {
        self.device = device
        self.localURL = localURL
        self.logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deviceshots-rec-\(UUID().uuidString).log")
        self.remotePath = device.kind == .android
            ? "/sdcard/deviceshots-\(UUID().uuidString).mp4"
            : nil
    }
}

/// Starts and stops screen recordings and delivers the finished video the way
/// screenshots are delivered: a file on the pasteboard, plus a copy in the
/// save folder when that setting is on.
@MainActor
final class VideoRecorder: ObservableObject {
    static let shared = VideoRecorder()

    /// Device IDs currently recording.
    @Published private(set) var recording: Set<String> = []
    private var sessions: [String: RecordingSession] = [:]

    /// Android's screenrecord refuses to run longer than this.
    private static let androidTimeLimit = 180

    func isRecording(_ device: Device) -> Bool { recording.contains(device.id) }

    func toggle(_ device: Device) {
        if isRecording(device) { stop(device) } else { start(device) }
    }

    func start(_ device: Device) {
        guard device.canRecordVideo, sessions[device.id] == nil else { return }

        let defaults = UserDefaults.standard
        let includeDevice = defaults.object(forKey: Prefs.filenameIncludesDevice) == nil
            || defaults.bool(forKey: Prefs.filenameIncludesDevice)
        let directory = defaults.bool(forKey: Prefs.saveToFolder)
            ? URL(fileURLWithPath: defaults.string(forKey: Prefs.saveFolderPath) ?? Prefs.defaultFolder)
            : FileManager.default.temporaryDirectory
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = includeDevice ? screenshotFilenameBase(device.name, includeDevice: true) : "Screenshot"
        let name = "\(base == "Screenshot" ? "Recording" : base) \(formatter.string(from: Date()))"
        let ext = device.kind == .android ? "mp4" : "mov"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail(device, error.localizedDescription)
            return
        }
        let session = RecordingSession(
            device: device,
            localURL: directory.appendingPathComponent("\(name).\(ext)")
        )

        switch device.kind {
        case .simulator:
            guard let developerDir = xcodeDeveloperDirectory else {
                fail(device, "Xcode with simctl was not found")
                return
            }
            session.process.executableURL = URL(fileURLWithPath: xcrunPath)
            session.process.arguments = ["simctl", "io", device.id, "recordVideo",
                                         "--codec", "h264", "--force", session.localURL.path]
            session.process.environment = ProcessInfo.processInfo.environment
                .merging(["DEVELOPER_DIR": developerDir]) { _, override in override }
        case .android:
            guard let adbPath, let remote = session.remotePath else {
                fail(device, "adb not found")
                return
            }
            session.process.executableURL = URL(fileURLWithPath: adbPath)
            session.process.arguments = ["-s", device.id, "shell", "screenrecord",
                                         "--time-limit", "\(Self.androidTimeLimit)", remote]
        case .ios:
            fail(device, "Recording isn't available for physical iOS devices")
            return
        }

        // stderr goes to a file rather than a pipe: adb can leave its server
        // holding the pipe open, which would block reading it after exit.
        FileManager.default.createFile(atPath: session.logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: session.logURL)
        session.process.standardOutput = log
        session.process.standardError = log
        session.process.terminationHandler = { [weak self] _ in
            try? log?.close()
            Task { @MainActor in await self?.finish(session) }
        }

        do {
            try session.process.run()
        } catch {
            fail(device, error.localizedDescription)
            return
        }
        sessions[device.id] = session
        recording.insert(device.id)
        RecordingHUD.shared.show(deviceID: device.id, deviceName: device.name, startedAt: session.startedAt) { [weak self] in
            self?.stop(device)
        }
    }

    func stop(_ device: Device) {
        guard let session = sessions[device.id], !session.stopRequested else { return }
        session.stopRequested = true
        RecordingHUD.shared.markStopping(deviceID: device.id)
        switch device.kind {
        case .simulator:
            // simctl finalizes the movie on SIGINT.
            session.process.interrupt()
        case .android:
            // The signal has to reach screenrecord on the device; killing the
            // local adb client would leave the mp4 unfinished.
            Task { _ = await runADBCommand(["-s", device.id, "shell", "pkill -2 screenrecord || killall -2 screenrecord"]) }
        case .ios:
            break
        }
    }

    /// Finalizes every recording before the app quits. Android recordings are
    /// only interrupted (stopped cleanly on the device); they aren't pulled.
    func stopAllForShutdown() {
        for session in sessions.values {
            session.process.terminationHandler = nil
            session.stopRequested = true
            switch session.device.kind {
            case .simulator:
                session.process.interrupt()
                let deadline = Date().addingTimeInterval(3)
                while session.process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            case .android:
                if let adbPath {
                    let kill = Process()
                    kill.executableURL = URL(fileURLWithPath: adbPath)
                    kill.arguments = ["-s", session.device.id, "shell", "pkill -2 screenrecord"]
                    kill.standardOutput = Pipe()
                    kill.standardError = Pipe()
                    try? kill.run()
                    kill.waitUntilExit()
                }
                session.process.terminate()
            case .ios:
                break
            }
        }
        sessions.removeAll()
        recording.removeAll()
        RecordingHUD.shared.hideAll()
    }

    private func finish(_ session: RecordingSession) async {
        let device = session.device
        guard sessions[device.id] === session else { return }
        let log = (try? String(contentsOf: session.logURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: session.logURL)

        var problem: String?
        if let remote = session.remotePath {
            // The adb client can exit before screenrecord has finished writing
            // the file's index, so wait for the file to stop growing.
            await Self.waitForRemoteFileToSettle(device: device, path: remote)
            let pull = await runADBCommand(["-s", device.id, "pull", remote, session.localURL.path])
            _ = await runADBCommand(["-s", device.id, "shell", "rm", "-f", remote])
            if !pull.succeeded { problem = log.isEmpty ? pull.errorSummary : Self.summarize(log) }
        }
        if problem == nil, !Self.hasContent(session.localURL) {
            problem = log.isEmpty ? "No video was recorded" : Self.summarize(log)
        }
        if problem == nil, !MP4.isComplete(session.localURL) {
            problem = log.isEmpty ? "The recording was cut off and can't be played" : Self.summarize(log)
        }

        sessions[device.id] = nil
        recording.remove(device.id)
        RecordingHUD.shared.hide(deviceID: device.id)

        if let problem {
            try? FileManager.default.removeItem(at: session.localURL)
            fail(device, problem)
            return
        }
        deliver(session)
    }

    private func deliver(_ session: RecordingSession) {
        let defaults = UserDefaults.standard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([session.localURL as NSURL])

        if defaults.object(forKey: Prefs.playSound) == nil || defaults.bool(forKey: Prefs.playSound) {
            NSSound(named: "Pop")?.play()
        }
        let saved = defaults.bool(forKey: Prefs.saveToFolder)
        let atLimit = session.device.kind == .android
            && !session.stopRequested
            && Date().timeIntervalSince(session.startedAt) >= Double(Self.androidTimeLimit) - 2
        var note = saved ? "✓ Video copied · saved to folder" : "✓ Video copied to clipboard"
        if atLimit { note += " (3 min limit)" }
        setStatus(note, for: session.device, isError: false)
    }

    private func fail(_ device: Device, _ message: String) {
        setStatus(message, for: device, isError: true)
        DeviceStore.shared.signalError()
    }

    private func setStatus(_ message: String, for device: Device, isError: Bool) {
        let store = DeviceStore.shared
        store.status[device.id] = (message, isError)
        let shownAt = Date()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Date().timeIntervalSince(shownAt) >= 5.9 { store.status[device.id] = nil }
        }
    }

    private static func waitForRemoteFileToSettle(device: Device, path: String) async {
        var last = -1
        for _ in 0..<40 {
            let result = await runADBCommand(["-s", device.id, "shell", "stat", "-c", "%s", path])
            let size = Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            if size >= 0, size == last { return }
            last = size
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func hasContent(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return size > 0
    }

    private static func summarize(_ log: String) -> String {
        let lines = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last.map { String($0.suffix(200)) } ?? "Recording failed"
    }
}

/// Minimal MP4/MOV structure check. A recording that was killed before it was
/// finalized has media data but no `moov` box, so no player can open it.
enum MP4 {
    static func isComplete(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        var position: UInt64 = 0
        while position + 8 <= size {
            guard (try? handle.seek(toOffset: position)) != nil,
                  let header = try? handle.read(upToCount: 16), header.count >= 8
            else { return false }
            var boxSize = UInt64(header[0]) << 24 | UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "moov" { return true }
            if boxSize == 1, header.count >= 16 {
                boxSize = header[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
            } else if boxSize == 0 {
                boxSize = size - position
            }
            guard boxSize >= 8 else { return false }
            position += boxSize
        }
        return false
    }
}
