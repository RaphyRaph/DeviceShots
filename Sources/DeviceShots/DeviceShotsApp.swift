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

        storeObserver = Publishers.CombineLatest3(store.$devices, store.$status, store.$capturing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
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
            for (index, device) in store.devices.enumerated() {
                let item = NSMenuItem(title: deviceTitle(device, index: index), action: #selector(capture(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                item.isEnabled = device.available && !store.capturing.contains(device.id)
                item.image = NSImage(systemSymbolName: device.icon, accessibilityDescription: device.name)
                let subtitle = deviceSubtitle(device)
                if #available(macOS 14.4, *) {
                    item.subtitle = subtitle
                } else {
                    item.title += " — \(subtitle)"
                }
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

    private func deviceTitle(_ device: Device, index: Int) -> String {
        let shortcut = ShortcutStore.shared.captureShortcuts.indices.contains(index)
            ? ShortcutStore.shared.captureShortcuts[index]?.display
            : nil
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
        devices = found
        hasLoadedOnce = true
        isRefreshing = false
    }

    /// Entry point for global shortcuts: capture the Nth device in the list,
    /// optionally pasting into the frontmost app afterwards.
    /// Uses the cached device list so hotkeys don't wait on rediscovery; loads once if needed.
    func captureDevice(at index: Int, thenPaste: Bool = false) async {
        if LatencyOpts.forceHotkeyRefresh || !hasLoadedOnce {
            await refresh()
        }
        guard devices.indices.contains(index), devices[index].available else {
            signalError()
            return
        }
        _ = await capture(devices[index], thenPaste: thenPaste)
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

struct DeviceListView: View {
    @ObservedObject var store: DeviceStore
    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var listHeight: CGFloat {
        let setupRows = (store.devices.contains(where: { $0.kind == .ios }) ? 0 : 1)
            + (store.devices.contains(where: { $0.kind == .android }) ? 0 : 1)
        let rowCount = max(store.devices.count + setupRows, 1)
        return min(CGFloat(rowCount) * 44, 320)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear { Task { await store.refresh() } }
        .onReceive(refreshTimer) { _ in Task { await store.refresh() } }
    }

    private var header: some View {
        HStack {
            Text("Connected devices")
                .font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 20, height: 20)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .frame(width: 20, height: 20)
                .help("Refresh device list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if store.devices.isEmpty && !store.hasLoadedOnce {
            Text("Looking for devices…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            List {
                ForEach(store.devices) { device in
                    DeviceRow(
                        device: device,
                        index: store.devices.firstIndex(of: device) ?? 0,
                        store: store
                    )
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(.gray)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if !store.devices.contains(where: { $0.kind == .ios }) {
                    PlaceholderSetupRow(config: .ios)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if !store.devices.contains(where: { $0.kind == .android }) {
                    PlaceholderSetupRow(config: .android)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .deviceListContentMarginsRemoved()
            .padding(.horizontal, -8)
            .frame(height: listHeight)
        }
    }

    private var footer: some View {
        HStack {
            settingsButton
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var settingsButton: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Settings")
            }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })
        } else {
            Button("Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func deviceListContentMarginsRemoved() -> some View {
        if #available(macOS 14.0, *) {
            self
                .contentMargins([.top, .horizontal], 0, for: .scrollContent)
        } else {
            self
        }
    }
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

/// Shown when no device of a platform is detected; expands into setup instructions.
struct PlaceholderSetupRow: View {
    let config: SetupConfig
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: config.icon)
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(config.title)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text("Not detected — how to connect")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    let numberedSections = numbered(config.sections)
                    ForEach(numberedSections.indices, id: \.self) { sectionIndex in
                        let section = numberedSections[sectionIndex]
                        instructionsHeader(section.header)
                            .padding(.top, sectionIndex == 0 ? 0 : 4)
                        ForEach(section.steps, id: \.number) { item in
                            step(item.number, item.text)
                        }
                    }
                    if let warning = config.warning {
                        Text(.init("⚠️ " + warning))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.top, 4)
                    } else {
                        Text(config.footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private func numbered(_ sections: [(header: String, steps: [String])])
        -> [(header: String, steps: [(number: Int, text: String)])] {
        var counter = 0
        return sections.map { section in
            (section.header, section.steps.map { text in
                counter += 1
                return (counter, text)
            })
        }
    }

    private func instructionsHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func step(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\(number).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)
            Text(.init(markdown))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DeviceRow: View {
    let device: Device
    let index: Int
    @ObservedObject var store: DeviceStore
    @ObservedObject private var shortcuts = ShortcutStore.shared

    private var assignedShortcut: Shortcut? {
        shortcuts.captureShortcuts.indices.contains(index) ? shortcuts.captureShortcuts[index] : nil
    }


    @State private var isRowHovering = false
    var body: some View {
        Button {
            Task { await store.capture(device) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.icon)
                    .foregroundStyle(device.available ? .primary : .tertiary)
                .font(.title3)
                .frame(width: 24, height: 24)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .fontWeight(.medium)
                        .foregroundStyle(device.available ? .primary : .secondary)
                    if let status = store.status[device.id] {
                        Text(status.message)
                            .font(.caption)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    } else {
                        Text(device.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let assignedShortcut {
                    Text(assignedShortcut.display)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }

                    if store.capturing.contains(device.id) {
                        ProgressView().controlSize(.small)
                    } else if isRowHovering && device.available {
                        Image(systemName: "clipboard")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.available || store.capturing.contains(device.id))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(isRowHovering ? 0.10 : 0))
        .animation(.easeInOut(duration: 0.12), value: isRowHovering)
        .onHover { isRowHovering = $0 }
        .help(device.available ? "Hover to copy screenshot" : "Device not connected")
    }
}
