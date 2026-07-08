import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt      // NSEvent.ModifierFlags.rawValue

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// e.g. "⌥⇧1" — always shows the base key, not the shifted character
    var display: String {
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        return result + KeyDisplay.baseKeyName(keyCode)
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}

// MARK: - Global hotkey registration (Carbon — works without accessibility permission)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData!).takeUnretainedValue()
            center.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    func register(_ shortcut: Shortcut, handler: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53435348), id: id) // 'SCSH'
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return }
        refs[id] = ref
        handlers[id] = handler
    }
}

// MARK: - Persisted shortcut slots (Device 1…N)

@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()
    static let slotCount = 6
    private static let captureKey = "deviceShortcuts"
    private static let pasteKey = "devicePasteShortcuts"

    @Published var captureShortcuts: [Shortcut?] {
        didSet { save(captureShortcuts, key: Self.captureKey); registerAll() }
    }
    @Published var pasteShortcuts: [Shortcut?] {
        didSet { save(pasteShortcuts, key: Self.pasteKey); registerAll() }
    }

    private init() {
        captureShortcuts = Self.load(key: Self.captureKey)
        pasteShortcuts = Self.load(key: Self.pasteKey)
        registerAll()
    }

    private static func load(key: String) -> [Shortcut?] {
        var loaded = [Shortcut?](repeating: nil, count: slotCount)
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Shortcut?].self, from: data) {
            for (index, shortcut) in decoded.prefix(slotCount).enumerated() {
                loaded[index] = shortcut
            }
        }
        return loaded
    }

    private func save(_ shortcuts: [Shortcut?], key: String) {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func registerAll() {
        HotKeyCenter.shared.unregisterAll()
        for (index, shortcut) in captureShortcuts.enumerated() {
            guard let shortcut else { continue }
            HotKeyCenter.shared.register(shortcut) {
                Task { @MainActor in
                    await DeviceStore.shared.captureDevice(at: index)
                }
            }
        }
        for (index, shortcut) in pasteShortcuts.enumerated() {
            guard let shortcut else { continue }
            HotKeyCenter.shared.register(shortcut) {
                Task { @MainActor in
                    await DeviceStore.shared.captureDevice(at: index, thenPaste: true)
                }
            }
        }
    }
}

// MARK: - Key display helpers

enum KeyDisplay {
    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
    ]

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106]

    /// The key's unshifted name in the current keyboard layout ("1", "A", ";" …).
    static func baseKeyName(_ keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Recorder control (CleanShot-style "Record shortcut" button)

struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(isRecording ? "Type…" : (shortcut?.display ?? "Record"))
                    .font(.callout.monospaced())
                    .foregroundStyle(labelColor)
                    .frame(minWidth: 70)
            }
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.accentColor : .clear, lineWidth: 1.5)
            )

            Button {
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
            .disabled(shortcut == nil || isRecording)
        }
        .onDisappear { stopRecording() }
    }

    private var labelColor: Color {
        if isRecording { return .accentColor }
        return shortcut == nil ? .secondary : .primary
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil // swallow the event while recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let flags = event.modifierFlags.intersection(relevant)

        if event.keyCode == 53 { // Escape cancels
            stopRecording()
            return
        }
        if event.keyCode == 51 && flags.isEmpty { // Delete clears
            shortcut = nil
            stopRecording()
            return
        }
        // Require a real modifier (beyond shift alone) unless it's a function key.
        let isFunctionKey = KeyDisplay.functionKeyCodes.contains(event.keyCode)
        guard isFunctionKey || !flags.subtracting(.shift).isEmpty else {
            NSSound.beep()
            return
        }
        shortcut = Shortcut(keyCode: event.keyCode, modifiers: flags.rawValue)
        stopRecording()
    }
}
