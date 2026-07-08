import SwiftUI
import AppKit

@main
struct ScreenshotterApp: App {
    @StateObject private var store = DeviceStore.shared
    @StateObject private var shortcuts = ShortcutStore.shared

    var body: some Scene {
        MenuBarExtra {
            DeviceListView(store: store)
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
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
    func captureDevice(at index: Int, thenPaste: Bool = false) async {
        await refresh()
        guard devices.indices.contains(index), devices[index].available else {
            NSSound(named: "Basso")?.play()
            return
        }
        let succeeded = await capture(devices[index])
        if succeeded && thenPaste {
            simulatePaste()
        }
    }

    /// Sends ⌘V to the frontmost app. Requires the Accessibility permission;
    /// prompts for it on first use.
    private func simulatePaste() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            NSSound(named: "Basso")?.play()
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // kVK_ANSI_V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    @discardableResult
    func capture(_ device: Device) async -> Bool {
        guard !capturing.contains(device.id) else { return false }
        capturing.insert(device.id)
        status[device.id] = ("Capturing…", false)

        let outcome = await DeviceDiscovery.captureScreenshot(of: device)
        capturing.remove(device.id)

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
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let base = includeDevice ? device.name : "Screenshot"
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
}

struct DeviceListView: View {
    @ObservedObject var store: DeviceStore
    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

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
            VStack(spacing: 0) {
                ForEach(Array(store.devices.enumerated()), id: \.element.id) { index, device in
                    DeviceRow(device: device, index: index, store: store)
                    if device != store.devices.last {
                        Divider().padding(.leading, 12)
                    }
                }
                if !store.devices.contains(where: { $0.kind == .ios }) {
                    if !store.devices.isEmpty { Divider().padding(.leading, 12) }
                    PlaceholderSetupRow(config: .ios)
                }
                if !store.devices.contains(where: { $0.kind == .android }) {
                    Divider().padding(.leading, 12)
                    PlaceholderSetupRow(config: .android)
                }
            }
            .padding(.vertical, 4)
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
            ? "adb was not found on this Mac. Install it with `brew install android-platform-tools`, then relaunch Screenshotter."
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
            : "Xcode is required to capture from iPhones, iPads, and simulators. Install it from the App Store, open it once to finish setup, then relaunch Screenshotter."
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


    @State private var isHovering = false

    var body: some View {
        Button {
            Task { await store.capture(device) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.icon)
                    .font(.title3)
                    .foregroundStyle(device.available ? .primary : .tertiary)
                    .frame(width: 24)

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
                        Text("\(device.kind.rawValue) · \(device.detail)")
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
                } else {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(isHovering && device.available ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isHovering && device.available ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!device.available || store.capturing.contains(device.id))
        .onHover { isHovering = $0 }
        .help(device.available ? "Copy screenshot to clipboard" : "Device not connected")
    }
}
