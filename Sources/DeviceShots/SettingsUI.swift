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

enum Prefs {
    static let clipboardMode = "clipboardMode"
    static let saveToFolder = "saveToFolder"
    static let saveFolderPath = "saveFolderPath"
    static let filenameIncludesDevice = "filenameIncludesDevice"
    static let playSound = "playSound"

    static var defaultFolder: String {
        (FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser).path
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
        Group {
            if #available(macOS 27.0, *) {
                modernSettingsTabs
            } else {
                legacySettingsTabs
            }
        }
        .frame(width: 640, height: 440)
    }

    /// The TabContent-based API gives macOS 27 control of the native settings
    /// title bar. Keep the legacy tab-item construction for macOS 26 and older.
    @available(macOS 27.0, *)
    private var modernSettingsTabs: some View {
        TabView(selection: $selection) {
            Tab(Section.capture.rawValue, systemImage: Section.capture.icon, value: Section.capture) {
                CaptureSettingsView()
            }
            Tab(Section.shortcuts.rawValue, systemImage: Section.shortcuts.icon, value: Section.shortcuts) {
                ShortcutsSettingsView()
            }
        }
    }

    private var legacySettingsTabs: some View {
        TabView(selection: $selection) {
            CaptureSettingsView()
                .tag(Section.capture)
                .tabItem { Label(Section.capture.rawValue, systemImage: Section.capture.icon) }
            ShortcutsSettingsView()
                .tag(Section.shortcuts)
                .tabItem { Label(Section.shortcuts.rawValue, systemImage: Section.shortcuts.icon) }
        }
    }
}

struct CaptureSettingsView: View {
    @AppStorage(Prefs.clipboardMode) private var clipboardMode = ClipboardMode.image.rawValue
    @AppStorage(Prefs.saveToFolder) private var saveToFolder = false
    @AppStorage(Prefs.saveFolderPath) private var saveFolderPath = Prefs.defaultFolder
    @AppStorage(Prefs.filenameIncludesDevice) private var filenameIncludesDevice = true
    @AppStorage(Prefs.playSound) private var playSound = true

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
        return "Example: \(name) 2026-07-08 at 14.30.52.png"
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
    @ObservedObject private var store = ShortcutStore.shared
    @ObservedObject private var devices = DeviceStore.shared

    private let columnWidth: CGFloat = 120

    var body: some View {
        Form {
            Section {
                LabeledContent(" ") {
                    HStack(spacing: 8) {
                        Text("Capture")
                            .frame(width: columnWidth)
                        Text("Capture & Paste")
                            .frame(width: columnWidth)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(0..<ShortcutStore.slotCount, id: \.self) { index in
                    LabeledContent(rowLabel(index)) {
                        HStack(spacing: 8) {
                            ShortcutRecorder(shortcut: $store.captureShortcuts[index])
                                .frame(width: columnWidth)
                            ShortcutRecorder(shortcut: $store.pasteShortcuts[index])
                                .frame(width: columnWidth)
                        }
                    }
                }
            } footer: {
                Text("Each shortcut targets the device at that position in the menu list, top to bottom. Capture copies the screenshot to the clipboard; Capture & Paste also pastes it into the frontmost app (requires the Accessibility permission, prompted on first use).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await devices.refresh() }
    }

    private func rowLabel(_ index: Int) -> String {
        let name = devices.devices.indices.contains(index)
            ? devices.devices[index].name
            : "Connected device"
        return "\(index + 1). \(name)"
    }
}
