import SwiftUI
import AppKit
import Combine
import os

let discoveryLog = Logger(subsystem: "com.raphael.deviceshots", category: "discovery")

/// The app's scenes. The `@main` entry point lives in the thin DeviceShots
/// executable target so this code can be a library (Xcode can't preview
/// SwiftUI in a package's executable target).
public struct DeviceShotsScenes: Scene {
    public init() {}

    public var body: some Scene {
        // Invisible scene that hands SwiftUI's openSettings action to the
        // AppKit menu; the private showSettingsWindow: selector no longer works.
        Window("Settings Bridge", id: SettingsBridge.windowID) {
            SettingsBridge()
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
enum SettingsOpener {
    fileprivate static var action: OpenSettingsAction?

    static func open() {
        action?()
        NSApp.activate()
    }
}

private struct SettingsBridge: View {
    static let windowID = "settings-bridge"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                SettingsOpener.action = openSettings
                // Keep the scene alive (so the action stays valid) but off screen.
                NSApp.windows
                    .filter { $0.identifier?.rawValue.hasPrefix(Self.windowID) == true }
                    .forEach { $0.orderOut(nil) }
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

        if store.devices.isEmpty {
            let scanning = NSMenuItem(title: "Scanning for devices…", action: nil, keyEquivalent: "")
            scanning.isEnabled = false
            menu.addItem(scanning)
        } else {
            let header = NSMenuItem(title: store.isRefreshing ? "Refreshing devices…" : "Connected Devices", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

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
        let shortcut = slot.flatMap { SlotStore.shared.state.shortcut(.capture, slot: $0)?.display }
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
        SettingsOpener.open()
    }

    @objc private func showSetup(_ sender: NSMenuItem) {
        (sender.representedObject as? SetupConfig)?.showAlert()
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
public final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    override public init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = SlotStore.shared   // loads slots and registers their hotkeys
        statusItemController = StatusItemController(store: DeviceStore.shared)
        // Discover at launch so the menu and hotkeys don't start empty.
        Task { await DeviceStore.shared.refresh() }
        CaptureLatencyBench.runIfRequested()
    }

    /// Menu-bar app: hiding the settings bridge or closing Settings must not quit.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        shutdown()
        return .terminateNow
    }

    public func applicationWillTerminate(_ notification: Notification) {
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
        guard !isRefreshing else {
            discoveryLog.notice("refresh skipped: one already in flight")
            return
        }
        isRefreshing = true
        let started = Date()
        let found = await DeviceDiscovery.allDevices()
        discoveryLog.notice("refresh: \(found.count) device(s) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s: \(found.map { "\($0.kind.rawValue):\($0.name)[\($0.available ? "on" : "off")]" }.joined(separator: ", "), privacy: .public)")
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
        let slots = SlotStore.shared.state.slots
        guard slots.indices.contains(slot), let id = slots[slot].device?.persistentID else {
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
