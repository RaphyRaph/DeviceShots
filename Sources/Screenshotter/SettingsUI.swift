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

    @State private var selection: Section? = .capture

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 160, max: 180)
        } detail: {
            switch selection ?? .capture {
            case .capture: CaptureSettingsView()
            case .shortcuts: ShortcutsSettingsView()
            }
        }
        .frame(width: 640, height: 440)
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
                Picker("Copy to clipboard:", selection: $clipboardMode) {
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
                LabeledContent("Destination:") {
                    HStack {
                        Text(abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(saveToFolder ? .primary : .tertiary)
                        Button("Choose…", action: chooseFolder)
                            .disabled(!saveToFolder)
                    }
                }
                Toggle("Include device name in filename", isOn: $filenameIncludesDevice)
                Text(filenameExample)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play sound after successful capture", isOn: $playSound)
                Text("A failure always plays an error sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Capture")
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
        .navigationTitle("Shortcuts")
        .task { await devices.refresh() }
    }

    private func rowLabel(_ index: Int) -> String {
        let name = devices.devices.indices.contains(index)
            ? devices.devices[index].name
            : "Connected device"
        return "\(index + 1). \(name):"
    }
}
