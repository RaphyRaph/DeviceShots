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

    @State private var selection: Section = Self.initialSection

    private static var initialSection: Section {
        #if DEBUG
        if let tab = DebugHooks.settingsTab { return tab }
        #endif
        return .capture
    }

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
                // A second Text in a control's label renders as its subtitle,
                // keeping the caption in the same row (no divider).
                Picker(selection: $clipboardMode) {
                    ForEach(ClipboardMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                } label: {
                    Text("Copy to clipboard")
                    Text("Adjust this option if you've encountered any issues with pasting from clipboard or clipboard managers.")
                }
                .pickerStyle(.menu)

                Picker(selection: $androidCaptureFormat) {
                    ForEach(AndroidCaptureFormat.allCases) { format in
                        Text(format.label).tag(format.rawValue)
                    }
                } label: {
                    Text("Android format")
                    Text("JPEG is usually faster to capture. Falls back to PNG if the device doesn’t support JPEG screencap.")
                }
                .pickerStyle(.menu)
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
                    Toggle(isOn: $filenameIncludesDevice) {
                        Text("Include device name in filename")
                        Text(filenameExample)
                    }
                }
            }

            Section {
                Toggle(isOn: $playSound) {
                    Text("Play sound after successful capture")
                    Text("A failure always plays an error sound.")
                }
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

/// Live Shortcuts tab: feeds the slot list from the stores and polls
/// discovery while visible so connect/disconnect shows up live.
struct ShortcutsSettingsView: View {
    @ObservedObject private var slots = SlotStore.shared
    @ObservedObject private var devices = DeviceStore.shared

    var body: some View {
        ShortcutSlotsList(
            slots: slots.state.slots,
            connectedIDs: Set(devices.devices.filter(\.available).map(\.persistentID)),
            actions: .init(
                clear: { slots.clear(slot: $0) },
                drop: { slots.drop(persistentID: $0, on: $1) },
                setShortcut: { slots.setShortcut($0, kind: $1, slot: $2) }
            )
        )
        .task {
            while !Task.isCancelled {
                await devices.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// The slot list, driven only by its inputs so previews and snapshots can
/// render any state without real devices.
struct ShortcutSlotsList: View {
    struct Actions {
        var clear: (_ slot: Int) -> Void = { _ in }
        var drop: (_ persistentID: String, _ slot: Int) -> Void = { _, _ in }
        var setShortcut: (_ shortcut: Shortcut?, _ kind: ShortcutKind, _ slot: Int) -> Void = { _, _, _ in }
    }

    let slots: [Slot]
    let connectedIDs: Set<String>
    var actions = Actions()
    /// Shows the drag grip on this row as if hovered (previews/snapshots).
    var forceHoverSlot: Int?

    private let columnWidth: CGFloat = 120

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text("Device")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ShortcutColumnHeader(title: "Capture")
                        .frame(width: columnWidth)
                    ShortcutColumnHeader(title: "Capture & Paste")
                        .frame(width: columnWidth)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    slotRow(index, slot: slot)
                }
                // Spare row (index == count): drop a device here to move it,
                // or record a shortcut before its device arrives.
                slotRow(slots.count, slot: Slot())
            }
        }
        .formStyle(.grouped)
    }

    private func slotRow(_ index: Int, slot: Slot) -> some View {
        HStack(spacing: 8) {
            SlotDeviceCell(
                slotted: slot.device,
                isConnected: slot.device.map { connectedIDs.contains($0.persistentID) } ?? false,
                forceHover: forceHoverSlot == index,
                onClear: { actions.clear(index) },
                onDrop: { actions.drop($0, index) }
            )
            ShortcutRecorder(shortcut: binding(slot.capture, .capture, index))
                .frame(width: columnWidth)
            ShortcutRecorder(shortcut: binding(slot.paste, .paste, index))
                .frame(width: columnWidth)
        }
    }

    private func binding(_ value: Shortcut?, _ kind: ShortcutKind, _ index: Int) -> Binding<Shortcut?> {
        Binding(get: { value }, set: { actions.setShortcut($0, kind, index) })
    }
}

/// One slot's device: draggable when occupied, and a drop target for moving
/// or swapping devices between slots.
private struct SlotDeviceCell: View {
    let slotted: SlottedDevice?
    let isConnected: Bool
    var forceHover = false
    let onClear: () -> Void
    let onDrop: (String) -> Void

    @State private var isDropTargeted = false
    @State private var isHovering = false

    /// Same height whether the slot is empty, connected or disconnected.
    private static let height: CGFloat = 40

    var body: some View {
        content
            .padding(.trailing, 6)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
            .onHover { isHovering = $0 }
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
            HStack(spacing: 4) {
                DragHandle(payload: slotted.persistentID, name: slotted.name, isVisible: isHovering || forceHover)
                DeviceLabel(name: slotted.name,
                            status: isConnected ? "Connected" : "Disconnected",
                            statusColor: isConnected ? .green : .secondary,
                            isDimmed: !isConnected)
                Spacer(minLength: 4)
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Free this slot")
                .accessibilityLabel("Remove \(slotted.name) from this slot")
            }
        } else {
            HStack(spacing: 4) {
                Color.clear.frame(width: DragHandle.width)
                Text("Empty")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Leading grip, shown on row hover; the only place a drag can start.
private struct DragHandle: View {
    static let width: CGFloat = 18

    let payload: String
    let name: String
    let isVisible: Bool

    var body: some View {
        // SF Symbols has no 2×3 dot grid, so draw the grip directly.
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
            .foregroundStyle(.secondary)
            .frame(width: Self.width, height: 28)
            .contentShape(Rectangle())
            .opacity(isVisible ? 1 : 0)
            .draggable(payload) {
                DeviceLabel(name: name, status: nil)
                    .padding(6)
            }
            .help("Drag to move")
            .accessibilityLabel("Move \(name)")
    }
}

private struct DeviceLabel: View {
    let name: String
    let status: String?
    var statusColor: Color = .secondary
    var isDimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .lineLimit(1)
                .foregroundStyle(isDimmed ? .secondary : .primary)
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
