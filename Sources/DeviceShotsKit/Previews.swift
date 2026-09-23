#if DEBUG
import SwiftUI
import AppKit

/// Sample states shared by Xcode previews and the snapshot tests
/// (`./snapshots.sh`), so both show exactly the same scenarios.
enum Fixtures {
    static let iphone = SlottedDevice(Device(id: "IPHONE", name: "iPhone 15 Pro RG", detail: "",
                                             kind: .ios, available: true))
    static let pixel = SlottedDevice(Device(id: "57131FDCH0016C", name: "Pixel 10 Pro", detail: "",
                                            kind: .android, available: true, hardwareSerial: "57131FDCH0016C"))
    static let ipad = SlottedDevice(Device(id: "IPAD", name: "iPad Pro", detail: "",
                                           kind: .ios, available: true, isTablet: true))

    static let optCmd1 = Shortcut(keyCode: 18, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
    static let optCmd2 = Shortcut(keyCode: 19, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue)
    static let shiftCmd3 = Shortcut(keyCode: 20, modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue)
    static let ctrlCmd9 = Shortcut(keyCode: 25, modifiers: NSEvent.ModifierFlags([.control, .command]).rawValue)

    /// Connected + disconnected devices, and a slot with shortcuts but no device.
    static let slots: [Slot] = [
        Slot(device: iphone, paste: optCmd1),
        Slot(device: pixel, capture: shiftCmd3, paste: optCmd2),
        Slot(device: ipad),
        Slot(capture: ctrlCmd9),
    ]
    static let connectedIDs: Set<String> = [iphone.persistentID, pixel.persistentID]

    static let setupGuides: [(name: String, config: SetupConfig)] = [
        ("setup-ios-installed", .iosGuide(xcodeInstalled: true)),
        ("setup-ios-missing", .iosGuide(xcodeInstalled: false)),
        ("setup-android-installed", .androidGuide(adbInstalled: true)),
        ("setup-android-missing", .androidGuide(adbInstalled: false)),
    ]
}

#Preview("Shortcuts: devices") {
    ShortcutSlotsList(slots: Fixtures.slots, connectedIDs: Fixtures.connectedIDs)
        .frame(width: 640, height: 420)
}

#Preview("Shortcuts: grip on hover") {
    ShortcutSlotsList(slots: Fixtures.slots, connectedIDs: Fixtures.connectedIDs, forceHoverSlot: 1)
        .frame(width: 640, height: 420)
}

#Preview("Shortcuts: no devices") {
    ShortcutSlotsList(slots: [], connectedIDs: [])
        .frame(width: 640, height: 200)
}

#Preview("Shortcuts: interactive") {
    // Drag, clear and record shortcuts; runs the real slot rules on sample data.
    @Previewable @State var state = SlotState(slots: Fixtures.slots)
    ShortcutSlotsList(
        slots: state.slots,
        connectedIDs: Fixtures.connectedIDs,
        actions: .init(
            clear: { slot in
                let id = state.slots[slot].device?.persistentID
                state.clear(slot: slot, isConnected: id.map(Fixtures.connectedIDs.contains) ?? false)
            },
            drop: { id, slot in
                if let from = state.slotIndex(of: id) { state.move(from: from, to: slot) }
            },
            setShortcut: { state.setShortcut($0, kind: $1, slot: $2) }
        )
    )
    .frame(width: 640, height: 420)
}

#Preview("Capture") {
    CaptureSettingsView()
        .frame(width: 640, height: 440)
}

#Preview("Setup guides") {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(Fixtures.setupGuides, id: \.name) { guide in
                VStack(alignment: .leading, spacing: 8) {
                    Text(guide.name).font(.caption.monospaced()).foregroundStyle(.secondary)
                    SetupWindowContent(config: guide.config)
                }
            }
        }
        .padding()
    }
    .frame(width: 420, height: 800)
}
#endif
