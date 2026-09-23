import SwiftUI
import AppKit

enum ClipboardMode: String, CaseIterable, Identifiable {
    case image, file, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .image: return "Image only"
        case .file: return "File only"
        case .both: return "Image and file"
        }
    }
}

enum AndroidCaptureFormat: String, CaseIterable, Identifiable {
    case jpeg, png
    var id: String { rawValue }
    var label: String {
        switch self {
        case .jpeg: return "JPEG (faster)"
        case .png: return "PNG (lossless)"
        }
    }
}

enum Prefs {
    static let clipboardMode = "clipboardMode"
    static let saveToFolder = "saveToFolder"
    static let saveFolderPath = "saveFolderPath"
    static let filenameIncludesDevice = "filenameIncludesDevice"
    static let playSound = "playSound"
    static let androidCaptureFormat = "androidCaptureFormat"

    static var defaultFolder: String {
        (FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser).path
    }

    /// Defaults to JPEG when unset — faster on-device encode than PNG.
    static var androidCaptureFormatValue: AndroidCaptureFormat {
        let raw = UserDefaults.standard.string(forKey: androidCaptureFormat) ?? AndroidCaptureFormat.jpeg.rawValue
        return AndroidCaptureFormat(rawValue: raw) ?? .jpeg
    }
}

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case capture = "Capture"
        case shortcuts = "Shortcuts"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .capture: return "camera.viewfinder"
            case .shortcuts: return "keyboard"
            }
        }
    }

    @State private var selection: Section = .capture

    var body: some View {
        TabView(selection: $selection) {
            Tab(Section.capture.rawValue, systemImage: Section.capture.icon, value: Section.capture) {
                CaptureSettingsView()
            }
            Tab(Section.shortcuts.rawValue, systemImage: Section.shortcuts.icon, value: Section.shortcuts) {
                ShortcutsSettingsView()
            }
        }
        .frame(width: 640, height: 480)
    }
}

struct CaptureSettingsView: View {
    @AppStorage(Prefs.clipboardMode) private var clipboardMode = ClipboardMode.image.rawValue
    @AppStorage(Prefs.saveToFolder) private var saveToFolder = false
    @AppStorage(Prefs.saveFolderPath) private var saveFolderPath = Prefs.defaultFolder
    @AppStorage(Prefs.filenameIncludesDevice) private var filenameIncludesDevice = true
    @AppStorage(Prefs.playSound) private var playSound = true
    @AppStorage(Prefs.androidCaptureFormat) private var androidCaptureFormat = AndroidCaptureFormat.jpeg.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Copy to clipboard", selection: $clipboardMode) {
                    ForEach(ClipboardMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("Adjust this option if you've encountered any issues with pasting from clipboard or clipboard managers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Android format", selection: $androidCaptureFormat) {
                    ForEach(AndroidCaptureFormat.allCases) { format in
                        Text(format.label).tag(format.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("JPEG is usually faster to capture. Falls back to PNG if the device doesn’t support JPEG screencap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Save a copy to folder", isOn: $saveToFolder)
                if saveToFolder {
                    LabeledContent("Destination") {
                        HStack {
                            Text(abbreviatedPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    Toggle("Include device name in filename", isOn: $filenameIncludesDevice)
                    Text(filenameExample)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Play sound after successful capture", isOn: $playSound)
                Text("A failure always plays an error sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var abbreviatedPath: String {
        (saveFolderPath as NSString).abbreviatingWithTildeInPath
    }

    private var filenameExample: String {
        let name = filenameIncludesDevice ? "iPhone 15 Pro" : "Screenshot"
        let ext = androidCaptureFormat == AndroidCaptureFormat.jpeg.rawValue ? "jpg" : "png"
        return "Example: \(name) 2026-07-08 at 14.30.52.\(ext)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveFolderPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            saveFolderPath = url.path
        }
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @ObservedObject private var slots = SlotStore.shared
    @ObservedObject private var devices = DeviceStore.shared

    private let columnWidth: CGFloat = 120

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("Device")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Capture")
                        .frame(width: columnWidth)
                    Text("Capture & Paste")
                        .frame(width: columnWidth)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(0..<SlotState.count, id: \.self) { slot in
                    let slotted = slots.state.slots[slot]
                    HStack(spacing: 8) {
                        SlotDeviceCell(
                            slotted: slotted,
                            isConnected: slotted.map { devices.connectedDevice(persistentID: $0.persistentID) != nil } ?? false,
                            onClear: { slots.clear(slot: slot) },
                            onDrop: { slots.drop(persistentID: $0, on: slot) }
                        )
                        ShortcutRecorder(shortcut: $shortcuts.captureShortcuts[slot])
                            .frame(width: columnWidth)
                        ShortcutRecorder(shortcut: $shortcuts.pasteShortcuts[slot])
                            .frame(width: columnWidth)
                    }
                }
            } footer: {
                Text("Shortcuts belong to the slot. A newly connected device takes the first empty slot and keeps it while disconnected. Drag a device onto another slot to move it, or click × to free its slot. Capture & Paste also pastes into the frontmost app (requires the Accessibility permission, prompted on first use).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Other connected devices") {
                UnslottedDevicesView(
                    devices: devices.devices.filter { $0.available && slots.state.slotIndex(of: $0.persistentID) == nil },
                    onDrop: { slots.unslot(persistentID: $0) }
                )
            }
        }
        .formStyle(.grouped)
        .task {
            // Poll while visible so connect/disconnect shows up live.
            while !Task.isCancelled {
                await devices.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// One slot's device: draggable when occupied, and a drop target for moving
/// or swapping devices between slots.
private struct SlotDeviceCell: View {
    let slotted: SlottedDevice?
    let isConnected: Bool
    let onClear: () -> Void
    let onDrop: (String) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                if let id = items.first { onDrop(id) }
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active: isDropTargeted = true
                default: isDropTargeted = false
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let slotted {
            HStack(spacing: 8) {
                DeviceLabel(name: slotted.name, icon: slotted.icon,
                            status: isConnected ? "Connected" : "Disconnected",
                            isConnected: isConnected)
                Spacer(minLength: 4)
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Free this slot")
                .accessibilityLabel("Remove \(slotted.name) from this slot")
            }
            .draggable(slotted.persistentID) {
                DeviceLabel(name: slotted.name, icon: slotted.icon, status: nil, isConnected: true)
                    .padding(6)
            }
        } else {
            Text("Empty")
                .foregroundStyle(.tertiary)
        }
    }
}

/// Connected devices not in a slot. Drag one onto a slot to assign it; drop a
/// slotted device here to free its slot.
private struct UnslottedDevicesView: View {
    let devices: [Device]
    let onDrop: (String) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if devices.isEmpty {
                Text("None. Drag a device here to free its slot.")
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(devices) { device in
                    DeviceLabel(name: device.name, icon: device.icon,
                                status: device.kind == .simulator ? "Simulator" : device.detail,
                                isConnected: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .draggable(device.persistentID) {
                            DeviceLabel(name: device.name, icon: device.icon, status: nil, isConnected: true)
                                .padding(6)
                        }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : .clear)
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            items.forEach(onDrop)
        }
        .onDropSessionUpdated { session in
            switch session.phase {
            case .entering, .active: isDropTargeted = true
            default: isDropTargeted = false
            }
        }
    }
}

private struct DeviceLabel: View {
    let name: String
    let icon: String
    let status: String?
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isConnected ? .primary : .tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(1)
                    .foregroundStyle(isConnected ? .primary : .secondary)
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
