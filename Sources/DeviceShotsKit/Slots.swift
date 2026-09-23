import Foundation
import Combine

/// A device remembered in a slot. Kept while the device is disconnected so
/// its shortcuts don't move to another device.
struct SlottedDevice: Codable, Equatable {
    let persistentID: String
    var name: String
    var kind: DeviceKind
    var isTablet: Bool

    init(_ device: Device) {
        persistentID = device.persistentID
        name = device.name
        kind = device.kind
        isTablet = device.isTablet
    }
}

/// A row in the shortcuts list: an optional device and the slot's shortcuts.
struct Slot: Codable, Equatable, Identifiable {
    /// Stable row identity; positions shift when empty slots are removed.
    var id = UUID()
    var device: SlottedDevice?
    var capture: Shortcut?
    var paste: Shortcut?

    var isUnused: Bool { device == nil && capture == nil && paste == nil }
}

enum ShortcutKind {
    case capture, paste
}

/// Growable list of shortcut slots and the rules for filling them.
/// Pure value type so the rules are testable without discovery or UI.
///
/// Slots with no device and no shortcuts are removed. Settings shows one
/// extra spare row at index `slots.count`; writing to it appends a slot.
struct SlotState: Codable, Equatable {
    var slots: [Slot] = []
    /// Devices cleared while connected. They stay out of slots until they've
    /// been seen disconnected, so auto-assign doesn't put them straight back.
    var cleared: Set<String> = []

    func slotIndex(of persistentID: String) -> Int? {
        slots.firstIndex { $0.device?.persistentID == persistentID }
    }

    /// Applies a discovery pass: refreshes remembered names, re-arms cleared
    /// devices that have disconnected, and puts newly seen physical devices
    /// into the first slot without a device (inheriting its shortcuts), or a
    /// new slot at the end. Simulators are never auto-assigned.
    func reconciled(with devices: [Device]) -> SlotState {
        var next = self
        let connected = devices.filter(\.available)
        next.cleared.formIntersection(connected.map(\.persistentID))

        for index in next.slots.indices {
            guard let slotted = next.slots[index].device,
                  let match = connected.first(where: { $0.persistentID == slotted.persistentID })
            else { continue }
            next.slots[index].device = SlottedDevice(match)
        }

        for device in connected where device.kind != .simulator {
            guard next.slotIndex(of: device.persistentID) == nil,
                  !next.cleared.contains(device.persistentID)
            else { continue }
            if let free = next.slots.firstIndex(where: { $0.device == nil }) {
                next.slots[free].device = SlottedDevice(device)
            } else {
                next.slots.append(Slot(device: SlottedDevice(device)))
            }
        }
        next.compact()
        return next
    }

    /// Removes a device from its slot; the slot goes away if it has no
    /// shortcuts. A device cleared while connected isn't auto-assigned again
    /// until it reconnects.
    mutating func clear(slot: Int, isConnected: Bool) {
        guard slots.indices.contains(slot), let slotted = slots[slot].device else { return }
        slots[slot].device = nil
        if isConnected { cleared.insert(slotted.persistentID) }
        compact()
    }

    /// Moves a slotted device to another slot (or the spare row). Devices
    /// swap; shortcuts stay with their slot.
    mutating func move(from: Int, to: Int) {
        guard slots.indices.contains(from), from != to, to <= slots.count else { return }
        if to == slots.count { slots.append(Slot()) }
        let device = slots[from].device
        slots[from].device = slots[to].device
        slots[to].device = device
        compact()
    }

    mutating func setShortcut(_ shortcut: Shortcut?, kind: ShortcutKind, slot: Int) {
        guard slot <= slots.count else { return }
        if slot == slots.count {
            guard shortcut != nil else { return }
            slots.append(Slot())
        }
        switch kind {
        case .capture: slots[slot].capture = shortcut
        case .paste: slots[slot].paste = shortcut
        }
        compact()
    }

    func shortcut(_ kind: ShortcutKind, slot: Int) -> Shortcut? {
        guard slots.indices.contains(slot) else { return nil }
        switch kind {
        case .capture: return slots[slot].capture
        case .paste: return slots[slot].paste
        }
    }

    /// Menu order: slotted devices by slot, then the rest in discovery order.
    func ordered(_ devices: [Device]) -> [(device: Device, slot: Int?)] {
        let slotted = devices
            .compactMap { device in slotIndex(of: device.persistentID).map { (device: device, slot: $0) } }
            .sorted { $0.slot < $1.slot }
            .map { (device: $0.device, slot: Optional($0.slot)) }
        let rest = devices
            .filter { slotIndex(of: $0.persistentID) == nil }
            .map { (device: $0, slot: Int?.none) }
        return slotted + rest
    }

    private mutating func compact() {
        slots.removeAll(where: \.isUnused)
    }
}

@MainActor
final class SlotStore: ObservableObject {
    static let shared = SlotStore()
    private static let defaultsKey = "slots"

    @Published private(set) var state: SlotState {
        didSet {
            guard state != oldValue else { return }
            save()
            // Hotkeys are bound to slot positions, so re-register when any
            // slot's shortcuts change or slots are added/removed.
            if state.slots.map({ [$0.capture, $0.paste] }) != oldValue.slots.map({ [$0.capture, $0.paste] }) {
                registerHotKeys()
            }
        }
    }

    private init() {
        #if DEBUG
        if DebugHooks.isDemo {
            // Sample slots; save() and registerHotKeys() are no-ops in demo mode.
            state = SlotState(slots: Fixtures.slots)
            return
        }
        #endif
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SlotState.self, from: data) {
            state = decoded
        } else {
            // didSet doesn't run in init, so save the migrated layout explicitly.
            state = Self.migrateFixedSlots(defaults)
            save()
        }
        registerHotKeys()
    }

    private func save() {
        #if DEBUG
        if DebugHooks.isDemo { return }
        #endif
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// One-time import of the earlier fixed six-slot layout, where devices and
    /// shortcuts were stored as three parallel arrays.
    private static func migrateFixedSlots(_ defaults: UserDefaults) -> SlotState {
        struct Legacy: Decodable {
            var slots: [SlottedDevice?]
            var cleared: Set<String>
        }
        let decoder = JSONDecoder()
        let legacy = defaults.data(forKey: "deviceSlots").flatMap { try? decoder.decode(Legacy.self, from: $0) }
        let capture = defaults.data(forKey: "deviceShortcuts").flatMap { try? decoder.decode([Shortcut?].self, from: $0) } ?? []
        let paste = defaults.data(forKey: "devicePasteShortcuts").flatMap { try? decoder.decode([Shortcut?].self, from: $0) } ?? []
        let devices = legacy?.slots ?? []
        let count = max(devices.count, capture.count, paste.count)

        var state = SlotState(cleared: legacy?.cleared ?? [])
        state.slots = (0..<count).map { index in
            Slot(device: devices.indices.contains(index) ? devices[index] : nil,
                 capture: capture.indices.contains(index) ? capture[index] : nil,
                 paste: paste.indices.contains(index) ? paste[index] : nil)
        }
        state.slots.removeAll(where: \.isUnused)
        return state
    }

    func reconcile(with devices: [Device]) {
        let next = state.reconciled(with: devices)
        if next != state { state = next }
    }

    func clear(slot: Int) {
        guard state.slots.indices.contains(slot), let id = state.slots[slot].device?.persistentID else { return }
        state.clear(slot: slot, isConnected: DeviceStore.shared.connectedDevice(persistentID: id) != nil)
    }

    /// Handles a drag payload (a slotted device's persistent ID) dropped on a slot.
    func drop(persistentID: String, on slot: Int) {
        guard let from = state.slotIndex(of: persistentID) else { return }
        state.move(from: from, to: slot)
    }

    func setShortcut(_ shortcut: Shortcut?, kind: ShortcutKind, slot: Int) {
        state.setShortcut(shortcut, kind: kind, slot: slot)
    }

    private func registerHotKeys() {
        #if DEBUG
        if DebugHooks.isDemo { return }
        #endif
        HotKeyCenter.shared.unregisterAll()
        for (index, slot) in state.slots.enumerated() {
            if let capture = slot.capture {
                HotKeyCenter.shared.register(capture) {
                    Task { @MainActor in await DeviceStore.shared.captureSlot(index) }
                }
            }
            if let paste = slot.paste {
                HotKeyCenter.shared.register(paste) {
                    Task { @MainActor in await DeviceStore.shared.captureSlot(index, thenPaste: true) }
                }
            }
        }
    }
}
