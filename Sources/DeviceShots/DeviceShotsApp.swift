import SwiftUI
import AppKit
import Combine

@main
struct DeviceShotsApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// Owns the native menu-bar item and its dynamic AppKit menu.
@MainActor
private final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let store: DeviceStore
    private var storeObserver: AnyCancellable?
    private var captureObserver: AnyCancellable?
    private var errorObserver: AnyCancellable?

    init(store: DeviceStore) {
        self.store = store
        super.init()

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.toolTip = "Device Shots"
        statusItem.menu = menu
        menu.delegate = self

        storeObserver = Publishers.CombineLatest4(store.$devices, store.$status, store.$capturing, SlotStore.shared.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.rebuildMenu()
            }
        captureObserver = store.$capturing
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] isCapturing in
                self?.updateIcon(isCapturing: isCapturing)
            }
        errorObserver = store.$errorFeedbackSequence
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.shakeIcon()
            }

        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        Task { await store.refresh() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(title: store.isRefreshing ? "Refreshing devices…" : "Connected Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if store.devices.isEmpty {
            let empty = NSMenuItem(title: store.hasLoadedOnce ? "No devices detected" : "Looking for devices…", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // Disconnected slotted devices aren't in store.devices, so they're
            // naturally left out; connected ones appear in slot order.
            for (device, slot) in SlotStore.shared.state.ordered(store.devices) {
                let item = NSMenuItem(title: deviceTitle(device, slot: slot), action: #selector(capture(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.isEnabled = device.available && !store.capturing.contains(device.id)
                item.image = NSImage(systemSymbolName: device.icon, accessibilityDescription: device.name)
                item.subtitle = deviceSubtitle(device)
                item.toolTip = device.available ? "Capture" : "Device not connected"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addSetupItem(for: .ios, whenMissingFrom: menu)
        addSetupItem(for: .android, whenMissingFrom: menu)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Device Shots", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func deviceTitle(_ device: Device, slot: Int?) -> String {
        let shortcut = slot.flatMap { ShortcutStore.shared.captureShortcuts[$0]?.display }
        let shortcutSuffix = shortcut.map { "\t\($0)" } ?? ""
        return "\(device.name)\(shortcutSuffix)"
    }

    private func deviceSubtitle(_ device: Device) -> String {
        store.status[device.id]?.message ?? (device.available ? device.detail : "Not connected")
    }

    private func updateIcon(isCapturing: Bool) {
        guard let button = statusItem.button,
              let image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "Device Shots"
              )?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        else { return }

        image.isTemplate = true
        button.setAccessibilityLabel(isCapturing ? "Capturing screenshot" : "Device Shots")
        button.image = image
        button.layer?.removeAnimation(forKey: "capturePulse")
    }

    private func shakeIcon() {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true

        let shake = CAKeyframeAnimation(keyPath: "position.x")
        shake.values = [0, -4, 4, -3, 3, -2, 2, 0]
        shake.keyTimes = [0, 0.12, 0.24, 0.38, 0.52, 0.66, 0.80, 1]
        shake.duration = 0.42
        shake.isAdditive = true
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(shake, forKey: "errorShake")
    }

    private func addSetupItem(for kind: DeviceKind, whenMissingFrom menu: NSMenu) {
        guard !store.devices.contains(where: { $0.kind == kind }) else { return }
        let config = kind == .ios ? SetupConfig.ios : SetupConfig.android
        let item = NSMenuItem(title: "Set up \(config.title)…", action: #selector(showSetup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = config
        menu.addItem(item)
    }

    @objc private func capture(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? Device else { return }
        Task { await store.capture(device) }
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSetup(_ sender: NSMenuItem) {
        guard let config = sender.representedObject as? SetupConfig else { return }
        let alert = NSAlert()
        alert.messageText = "Set up \(config.title)"
        var stepNumber = 0
        let instructions = config.sections.map { section in
            let steps = section.steps.map { step -> String in
                stepNumber += 1
                return "\(stepNumber). \(step)"
            }
            return ([section.header] + steps).joined(separator: "\n")
        }
        alert.informativeText = (instructions + [config.warning ?? config.footnote]).joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func tearDown() {
        storeObserver = nil
        captureObserver = nil
        errorObserver = nil
        menu.delegate = nil
        CaptureHUD.shared.tearDown()
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}

/// Owns the pieces of the app that are not managed by SwiftUI scenes.
/// In particular, MenuBarExtra windows can disappear without destroying the
/// process, so teardown must be tied to the application quit event.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(store: DeviceStore.shared)
        CaptureLatencyBench.runIfRequested()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdown()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdown()
    }

    private func shutdown() {
        statusItemController?.tearDown()
        statusItemController = nil
        HotKeyCenter.shared.unregisterAll()
        CommandProcessRegistry.shared.terminateAll()
        ADBServerLifecycle.shared.stopIfOwned(adbPath)
    }
}

@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()
    @Published var devices: [Device] = []
    @Published var isRefreshing = false
    @Published var hasLoadedOnce = false
    /// Per-device transient status shown in the row: (message, isError)
    @Published var status: [String: (message: String, isError: Bool)] = [:]
    @Published var capturing: Set<String> = []
    @Published private(set) var errorFeedbackSequence = 0
    /// Bumped on each clipboard delivery so deferred TIFF writes don't clobber a newer capture.
    private var deliveryGeneration = 0

    var isCapturingAnyDevice: Bool { !capturing.isEmpty }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let found = await DeviceDiscovery.allDevices()
        // Update slots before publishing devices so the menu rebuild sees both.
        SlotStore.shared.reconcile(with: found)
        devices = found
        hasLoadedOnce = true
        isRefreshing = false
    }

    func connectedDevice(persistentID: String) -> Device? {
        devices.first { $0.persistentID == persistentID && $0.available }
    }

    /// Entry point for global shortcuts: capture the device remembered in a
    /// slot, optionally pasting into the frontmost app afterwards.
    /// Uses the cached device list so hotkeys don't wait on rediscovery.
    func captureSlot(_ slot: Int, thenPaste: Bool = false) async {
        if LatencyOpts.forceHotkeyRefresh || !hasLoadedOnce {
            await refresh()
        }
        guard let id = SlotStore.shared.state.slots[slot]?.persistentID else {
            signalError()
            return
        }
        var device = connectedDevice(persistentID: id)
        if device == nil {
            // The cached list may predate a reconnect; check once before failing.
            await refresh()
            device = connectedDevice(persistentID: id)
        }
        guard let device else {
            signalError()
            return
        }
        _ = await capture(device, thenPaste: thenPaste)
    }

    /// Sends ⌘V to the frontmost app. Returns false when Accessibility access
    /// is unavailable, so Capture & Paste can report that the copy succeeded
    /// but the paste did not.
    private func simulatePaste() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            signalError()
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        return keyDown != nil && keyUp != nil
    }

    @discardableResult
    func capture(_ device: Device, thenPaste: Bool = false) async -> Bool {
        guard !capturing.contains(device.id) else { return false }
        capturing.insert(device.id)
        defer {
            capturing.remove(device.id)
            CaptureHUD.shared.hide()
        }
        status[device.id] = ("Capturing…", false)
        CaptureHUD.shared.show(for: device)

        let outcome = await DeviceDiscovery.captureScreenshot(of: device)

        let defaults = UserDefaults.standard
        let playSound = defaults.object(forKey: Prefs.playSound) == nil
            || defaults.bool(forKey: Prefs.playSound)

        var succeeded = false
        switch outcome {
        case .success(let png):
            do {
                let note = try deliver(png, from: device)
                status[device.id] = (note, false)
                succeeded = true
                if playSound { NSSound(named: "Pop")?.play() }
                if thenPaste && !simulatePaste() {
                    status[device.id] = ("✓ Copied — paste requires Accessibility access", false)
                }
            } catch {
                status[device.id] = (error.localizedDescription, true)
                signalError()
            }
        case .failure(let error):
            status[device.id] = (error.message, true)
            signalError()
        }

        let shownAt = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Only clear if nothing newer replaced it
            if Date().timeIntervalSince(shownAt) >= 3.9 {
                self?.status[device.id] = nil
            }
        }
        return succeeded
    }

    private func signalError() {
        errorFeedbackSequence &+= 1
        NSSound(named: "Tink")?.play()
    }

    /// Applies the capture preferences: clipboard mode, optional save to folder.
    /// Puts the image on the pasteboard first so paste/sound aren't blocked by TIFF encode or folder I/O.
    func deliver(_ imageData: Data, from device: Device) throws -> String {
        let defaults = UserDefaults.standard
        let mode = ClipboardMode(rawValue: defaults.string(forKey: Prefs.clipboardMode) ?? "") ?? .image
        let saveToFolder = defaults.bool(forKey: Prefs.saveToFolder)
        let includeDevice = defaults.object(forKey: Prefs.filenameIncludesDevice) == nil
            || defaults.bool(forKey: Prefs.filenameIncludesDevice)
        let format = ScreenshotFormat.detect(imageData)

        deliveryGeneration &+= 1
        let generation = deliveryGeneration

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch mode {
        case .image:
            switch LatencyOpts.tiffMode {
            case .skip:
                pasteboard.declareTypes([format.pasteboardType], owner: nil)
                pasteboard.setData(imageData, forType: format.pasteboardType)
                if saveToFolder {
                    Task.detached(priority: .utility) {
                        _ = try? writeScreenshotFile(
                            imageData,
                            format: format,
                            deviceName: device.name,
                            includeDevice: includeDevice,
                            saveToFolder: true
                        )
                    }
                }
            case .deferred:
                pasteboard.declareTypes([format.pasteboardType], owner: nil)
                pasteboard.setData(imageData, forType: format.pasteboardType)
                scheduleDeferredImageExtras(
                    imageData: imageData,
                    format: format,
                    deviceName: device.name,
                    includeDevice: includeDevice,
                    saveToFolder: saveToFolder,
                    generation: generation
                )
            case .sync:
                pasteboard.declareTypes([format.pasteboardType, .tiff], owner: nil)
                pasteboard.setData(imageData, forType: format.pasteboardType)
                if let image = NSImage(data: imageData), let tiff = image.tiffRepresentation {
                    pasteboard.setData(tiff, forType: .tiff)
                }
                if saveToFolder {
                    _ = try writeScreenshotFile(
                        imageData,
                        format: format,
                        deviceName: device.name,
                        includeDevice: includeDevice,
                        saveToFolder: true
                    )
                }
            }
        case .file:
            let fileURL = try writeScreenshotFile(
                imageData,
                format: format,
                deviceName: device.name,
                includeDevice: includeDevice,
                saveToFolder: saveToFolder
            )
            pasteboard.writeObjects([fileURL as NSURL])
        case .both:
            // File URL must exist before the pasteboard item is published; TIFF is skipped
            // here because amending an already-written NSPasteboardItem is unreliable.
            let fileURL = try writeScreenshotFile(
                imageData,
                format: format,
                deviceName: device.name,
                includeDevice: includeDevice,
                saveToFolder: saveToFolder
            )
            let item = NSPasteboardItem()
            item.setData(imageData, forType: format.pasteboardType)
            item.setString(fileURL.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        }

        return saveToFolder ? "✓ Copied · saved to folder" : "✓ Copied to clipboard"
    }

    /// TIFF re-encode and optional folder save run after the image is already pasteable.
    private func scheduleDeferredImageExtras(
        imageData: Data,
        format: ScreenshotFormat,
        deviceName: String,
        includeDevice: Bool,
        saveToFolder: Bool,
        generation: Int
    ) {
        Task { @MainActor [weak self] in
            // Let capture() finish Pop / ⌘V before spending main-thread time on TIFF.
            await Task.yield()
            guard let self, self.deliveryGeneration == generation else { return }
            if let image = NSImage(data: imageData), let tiff = image.tiffRepresentation {
                NSPasteboard.general.setData(tiff, forType: .tiff)
            }
        }
        if saveToFolder {
            Task.detached(priority: .utility) {
                _ = try? writeScreenshotFile(
                    imageData,
                    format: format,
                    deviceName: deviceName,
                    includeDevice: includeDevice,
                    saveToFolder: true
                )
            }
        }
    }
}

private enum ScreenshotFormat {
    case png, jpeg

    static func detect(_ data: Data) -> ScreenshotFormat {
        if data.count > 3, data[0] == 0xFF, data[1] == 0xD8, data[2] == 0xFF {
            return .jpeg
        }
        return .png
    }

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .png: return .png
        case .jpeg: return NSPasteboard.PasteboardType("public.jpeg")
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

private func writeScreenshotFile(
    _ data: Data,
    format: ScreenshotFormat,
    deviceName: String,
    includeDevice: Bool,
    saveToFolder: Bool
) throws -> URL {
    let defaults = UserDefaults.standard
    let directory = saveToFolder
        ? URL(fileURLWithPath: defaults.string(forKey: Prefs.saveFolderPath) ?? Prefs.defaultFolder)
        : FileManager.default.temporaryDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    let base = screenshotFilenameBase(deviceName, includeDevice: includeDevice)
    let url = directory.appendingPathComponent("\(base) \(formatter.string(from: Date())).\(format.fileExtension)")
    try data.write(to: url)
    return url
}

private func screenshotFilenameBase(_ deviceName: String, includeDevice: Bool) -> String {
    guard includeDevice else { return "Screenshot" }
    let unsafeCharacters = CharacterSet(charactersIn: "/:\u{0}")
    let cleaned = deviceName.components(separatedBy: unsafeCharacters)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Screenshot" : cleaned
}

struct SetupConfig {
    let icon: String
    let title: String
    /// Sections of (header, steps); steps are numbered continuously across sections.
    let sections: [(header: String, steps: [String])]
    let footnote: String
    let warning: String?    // shown instead of footnote when non-nil

    static let android = SetupConfig(
        icon: "apps.iphone",
        title: "Android device",
        sections: [
            ("On the Android device", [
                "Settings → About phone → tap **Build number** 7 times to enable Developer options.",
                "Settings → System → **Developer options** → turn on **USB debugging**.",
                "Connect the device to this Mac with a USB data cable.",
                "Tap **Allow** on the “Allow USB debugging?” prompt (check “Always allow from this computer”).",
            ]),
            ("On this Mac", [
                "If macOS asks “Allow accessory to connect?”, click **Allow**.",
            ]),
        ],
        footnote: "The device will appear here automatically once connected. If it shows as “unauthorized”, the allow prompt is still waiting on the phone’s screen.",
        warning: adbPath == nil
            ? "adb was not found on this Mac. Install it with `brew install android-platform-tools`, then relaunch Device Shots."
            : nil
    )

    static let ios = SetupConfig(
        icon: "apps.iphone",
        title: "iPhone / iPad",
        sections: [
            ("On the iPhone or iPad", [
                "Connect the device to this Mac with a USB cable.",
                "Unlock it and tap **Trust** when asked to trust this computer.",
                "Enable Settings → Privacy & Security → **Developer Mode** (the device restarts, required for screenshots).",
            ]),
            ("On this Mac", [
                "If macOS asks “Allow accessory to connect?”, click **Allow**.",
                "First-time pairing can take a minute while the device prepares for development.",
            ]),
        ],
        footnote: "The device will appear here automatically once connected. After the first pairing, capture also works over Wi‑Fi when the device is on the same network.",
        warning: hasXcodeTools
            ? nil
            : "Xcode is required to capture from iPhones, iPads, and simulators. Install it from the App Store, open it once to finish setup, then relaunch Device Shots."
    )
}
