import AppKit
import Carbon.HIToolbox
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt      // NSEvent.ModifierFlags.rawValue

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = ShortcutKey.normalizedKeyCode(keyCode)
        self.modifiers = Shortcut.normalizedModifiers(modifiers)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            keyCode: try container.decode(UInt16.self, forKey: .keyCode),
            modifiers: try container.decode(UInt.self, forKey: .modifiers)
        )
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// Numpad digits and the number row represent the same logical shortcut.
    var physicalKeyCodes: [UInt16] { ShortcutKey.physicalKeyCodes(for: keyCode) }

    private static func normalizedModifiers(_ rawValue: UInt) -> UInt {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        // This removes device-dependent bits that distinguish the left and
        // right modifier keys, leaving only their logical meaning.
        let independent = NSEvent.ModifierFlags(rawValue: rawValue)
            .intersection(.deviceIndependentFlagsMask)
        return independent.intersection(relevant).rawValue
    }

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

/// Maps physical digit keys to a logical digit. Carbon hotkeys themselves are
/// position-based, so each logical digit is registered for both locations.
enum ShortcutKey {
    private static let numberRowByKeypad: [UInt16: UInt16] = [
        82: 29, // 0
        83: 18, // 1
        84: 19, // 2
        85: 20, // 3
        86: 21, // 4
        87: 23, // 5
        88: 22, // 6
        89: 26, // 7
        91: 28, // 8
        92: 25, // 9
    ]

    static func normalizedKeyCode(_ keyCode: UInt16) -> UInt16 {
        numberRowByKeypad[keyCode] ?? keyCode
    }

    static func physicalKeyCodes(for keyCode: UInt16) -> [UInt16] {
        let canonical = normalizedKeyCode(keyCode)
        guard let keypad = numberRowByKeypad.first(where: { $0.value == canonical })?.key else {
            return [canonical]
        }
        return [canonical, keypad]
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
        for keyCode in shortcut.physicalKeyCodes {
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x53435348), id: id) // 'SCSH'
            let status = RegisterEventHotKey(UInt32(keyCode), shortcut.carbonModifiers,
                                             hotKeyID, GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { continue }
            refs[id] = ref
            handlers[id] = handler
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
    /// Fixed trailing slot for the clear button, reserved even when hidden so
    /// column headers can align with the record button (see `ShortcutColumnHeader`).
    static let clearSlotWidth: CGFloat = 16
    static let spacing: CGFloat = 4

    @Binding var shortcut: Shortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: Self.spacing) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(isRecording ? "Type…" : (shortcut?.display ?? "Record"))
                    .font(.callout.monospaced())
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity)
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
            .frame(width: Self.clearSlotWidth)
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
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(relevant)

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

/// Column title centered over the record button, not the whole recorder.
struct ShortcutColumnHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: ShortcutRecorder.spacing) {
            Text(title)
                .frame(maxWidth: .infinity)
            Color.clear
                .frame(width: ShortcutRecorder.clearSlotWidth, height: 1)
        }
    }
}
