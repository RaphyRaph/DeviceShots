import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct DeviceShotsApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var appLifecycle

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// Owns the real AppKit status item. A `MenuBarExtra` label is a SwiftUI
/// snapshot, so embedded AppKit views can be measured as empty and symbol
/// effects do not get a stable layer to animate in.
@MainActor
private final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let store: DeviceStore
    private var captureObserver: AnyCancellable?
    private let symbolImageView = NSImageView()
    private var visualWindow: NSPanel?

    init(store: DeviceStore) {
        self.store = store
        let isVisualCapture = ProcessInfo.processInfo.environment["DEVICESHOTS_VISUAL_OPEN_POPOVER"] == "1"
        popover.behavior = isVisualCapture ? .applicationDefined : .transient
        popover.contentViewController = NSHostingController(rootView: DeviceListView(store: store))
        super.init()

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.imagePosition = .imageOnly
        button.toolTip = "Device Shots"
        button.image = nil

        symbolImageView.frame = button.bounds
        symbolImageView.autoresizingMask = [.width, .height]
        symbolImageView.imageAlignment = .alignCenter
        symbolImageView.imageScaling = .scaleProportionallyDown
        symbolImageView.contentTintColor = .labelColor
        button.addSubview(symbolImageView)

        captureObserver = store.$capturing
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] isCapturing in
                self?.updateIcon(isCapturing: isCapturing)
            }

        let visualState = ProcessInfo.processInfo.environment["DEVICESHOTS_VISUAL_STATE"]
        updateIcon(isCapturing: visualState == "capturing")
        if ProcessInfo.processInfo.environment["DEVICESHOTS_VISUAL_OPEN_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showVisualWindow()
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Stable host for the CLI visual script. `NSPopover` closes immediately
    /// when opened programmatically by an accessory app, while this panel
    /// renders the identical `DeviceListView` long enough to capture.
    private func showVisualWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Device Shots Visual QA"
        panel.contentView = NSHostingView(rootView: DeviceListView(store: store))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        visualWindow = panel
    }

    private func updateIcon(isCapturing: Bool) {
        guard let button = statusItem.button,
              let image = NSImage(
                systemSymbolName: isCapturing ? "ellipsis.circle" : "camera.viewfinder",
                accessibilityDescription: "Device Shots"
              )?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        else { return }

        button.setAccessibilityLabel(isCapturing ? "Capturing screenshot" : "Device Shots")

        if #available(macOS 14.0, *) {
            symbolImageView.removeAllSymbolEffects(animated: false)
            symbolImageView.setSymbolImage(image, contentTransition: .replace.downUp)
            if isCapturing {
                if #available(macOS 15.0, *) {
                    symbolImageView.addSymbolEffect(.pulse, options: .repeat(.continuous))
                } else {
                    symbolImageView.addSymbolEffect(.pulse)
                }
            }
        } else {
            symbolImageView.image = image
        }
    }

    func tearDown() {
        captureObserver = nil
        popover.performClose(nil)
        visualWindow?.close()
        visualWindow = nil
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
    private static let deviceOrderKey = "deviceOrder"

    @Published var devices: [Device] = []
    @Published var isRefreshing = false
    @Published var hasLoadedOnce = false
    /// Per-device transient status shown in the row: (message, isError)
    @Published var status: [String: (message: String, isError: Bool)] = [:]
    @Published var capturing: Set<String> = []

    var isCapturingAnyDevice: Bool { !capturing.isEmpty }

    private var preferredOrder: [String] = UserDefaults.standard.stringArray(forKey: deviceOrderKey) ?? []

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let found = await DeviceDiscovery.allDevices()
        devices = DeviceOrder.applying(preferredOrder, to: found)
        hasLoadedOnce = true
        isRefreshing = false
    }

    /// Moves a device before another row and keeps that order across refreshes
    /// and relaunches. Shortcut slots resolve against this same `devices` array.
    func moveDevice(id: String, before targetID: String) {
        let reordered = DeviceOrder.moving(devices, id: id, before: targetID)
        guard reordered.map(\.id) != devices.map(\.id) else { return }
        devices = reordered
        preferredOrder = reordered.map(\.id)
        UserDefaults.standard.set(preferredOrder, forKey: Self.deviceOrderKey)
    }

    func moveDevice(id: String, to destination: Int) {
        let reordered = DeviceOrder.moving(devices, id: id, to: destination)
        guard reordered.map(\.id) != devices.map(\.id) else { return }
        devices = reordered
        preferredOrder = reordered.map(\.id)
        UserDefaults.standard.set(preferredOrder, forKey: Self.deviceOrderKey)
    }

    func moveDevices(from source: IndexSet, to destination: Int) {
        let reordered = DeviceOrder.moving(devices, from: source, to: destination)
        guard reordered.map(\.id) != devices.map(\.id) else { return }
        devices = reordered
        preferredOrder = reordered.map(\.id)
        UserDefaults.standard.set(preferredOrder, forKey: Self.deviceOrderKey)
    }

    /// Entry point for global shortcuts: capture the Nth device in the list,
    /// optionally pasting into the frontmost app afterwards.
    func captureDevice(at index: Int, thenPaste: Bool = false) async {
        await refresh()
        guard devices.indices.contains(index), devices[index].available else {
            NSSound(named: "Basso")?.play()
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
            NSSound(named: "Basso")?.play()
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
        defer { capturing.remove(device.id) }
        status[device.id] = ("Capturing…", false)

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
                NSSound(named: "Basso")?.play()
            }
        case .failure(let error):
            status[device.id] = (error.message, true)
            NSSound(named: "Basso")?.play()
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

    /// Applies the capture preferences: clipboard mode, optional save to folder.
    /// Returns the status message to show.
    private func deliver(_ png: Data, from device: Device) throws -> String {
        let defaults = UserDefaults.standard
        let mode = ClipboardMode(rawValue: defaults.string(forKey: Prefs.clipboardMode) ?? "") ?? .image
        let saveToFolder = defaults.bool(forKey: Prefs.saveToFolder)
        let includeDevice = defaults.object(forKey: Prefs.filenameIncludesDevice) == nil
            || defaults.bool(forKey: Prefs.filenameIncludesDevice)

        var fileURL: URL?
        if saveToFolder || mode != .image {
            let directory = saveToFolder
                ? URL(fileURLWithPath: defaults.string(forKey: Prefs.saveFolderPath) ?? Prefs.defaultFolder)
                : FileManager.default.temporaryDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let base = filenameBase(device.name, includeDevice: includeDevice)
            let url = directory.appendingPathComponent("\(base) \(formatter.string(from: Date())).png")
            try png.write(to: url)
            fileURL = url
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch mode {
        case .image:
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            pasteboard.setData(png, forType: .png)
            if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        case .file:
            if let fileURL { pasteboard.writeObjects([fileURL as NSURL]) }
        case .both:
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            if let fileURL {
                item.setString(fileURL.absoluteString, forType: .fileURL)
            }
            pasteboard.writeObjects([item])
        }

        return saveToFolder ? "✓ Copied · saved to folder" : "✓ Copied to clipboard"
    }

    private func filenameBase(_ deviceName: String, includeDevice: Bool) -> String {
        guard includeDevice else { return "Screenshot" }
        let unsafeCharacters = CharacterSet(charactersIn: "/:\u{0}")
        let cleaned = deviceName.components(separatedBy: unsafeCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Screenshot" : cleaned
    }
}

struct DeviceListView: View {
    @ObservedObject var store: DeviceStore
    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()
    @State private var draggedDeviceID: String?

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
                        store: store,
                        onDragStart: { draggedDeviceID = device.id }
                    )
                    .listRowSeparator(.visible)
                    .listRowSeparatorTint(.gray)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: DeviceReorderDropDelegate(
                            target: device,
                            store: store,
                            draggedDeviceID: $draggedDeviceID
                        )
                    )
                }
                .onMove(perform: store.moveDevices)

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

private struct DeviceReorderDropDelegate: DropDelegate {
    let target: Device
    @ObservedObject var store: DeviceStore
    @Binding var draggedDeviceID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedDeviceID,
              draggedDeviceID != target.id,
              let sourceIndex = store.devices.firstIndex(where: { $0.id == draggedDeviceID }),
              let targetIndex = store.devices.firstIndex(where: { $0.id == target.id })
        else { return }

        if sourceIndex < targetIndex {
            store.moveDevice(id: draggedDeviceID, to: targetIndex + 1)
        } else {
            store.moveDevice(id: draggedDeviceID, before: target.id)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedDeviceID = nil
        return true
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
    let onDragStart: () -> Void
    @ObservedObject private var shortcuts = ShortcutStore.shared

    private var assignedShortcut: Shortcut? {
        shortcuts.captureShortcuts.indices.contains(index) ? shortcuts.captureShortcuts[index] : nil
    }


    @State private var isRowHovering = false
    @State private var isIconHovering = false

    private var showsGrabber: Bool {
        isIconHovering || (index == 0 && ProcessInfo.processInfo.environment["DEVICESHOTS_VISUAL_HOVER_FIRST_DEVICE"] == "1")
    }

    var body: some View {
        Button {
            Task { await store.capture(device) }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if showsGrabber {
                        GrabberIcon()
                            .foregroundStyle(device.available ? .secondary : .tertiary)
                            .help("Drag to reorder devices and shortcut positions")
                    } else {
                        Image(systemName: device.icon)
                            .foregroundStyle(device.available ? .primary : .tertiary)
                    }
                }
                .font(.title3)
                .frame(width: 24, height: 24)
                .onHover { isIconHovering = $0 }
                .onDrag {
                    onDragStart()
                    return NSItemProvider(object: device.id as NSString)
                }

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

/// A six-dot drag affordance, matching macOS list reordering conventions.
private struct GrabberIcon: View {
    var body: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .frame(width: 24, height: 24)
    }
}
