import Foundation
import Combine

/// A device remembered in a shortcut slot. Kept while the device is
/// disconnected so its shortcuts don't move to another device.
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

    var icon: String { isTablet ? "apps.ipad" : "apps.iphone" }
}

/// Fixed list of shortcut slots and the rules for filling them.
/// Pure value type so the rules are testable without discovery or UI.
struct SlotState: Codable, Equatable {
    static let count = 6

    var slots: [SlottedDevice?] = Array(repeating: nil, count: count)
    /// Devices cleared while connected. They stay out of slots until they've
    /// been seen disconnected, so auto-assign doesn't put them straight back.
    var cleared: Set<String> = []

    func slotIndex(of persistentID: String) -> Int? {
        slots.firstIndex { $0?.persistentID == persistentID }
    }

    /// Applies a discovery pass: refreshes remembered names, re-arms cleared
    /// devices that have disconnected, and puts newly seen physical devices
    /// into the first free slot. Simulators are only slotted by hand.
    func reconciled(with devices: [Device]) -> SlotState {
        var next = self
        let connected = devices.filter(\.available)
        next.cleared.formIntersection(connected.map(\.persistentID))

        for index in next.slots.indices {
            guard let slotted = next.slots[index],
                  let match = connected.first(where: { $0.persistentID == slotted.persistentID })
            else { continue }
            next.slots[index] = SlottedDevice(match)
        }

        for device in connected where device.kind != .simulator {
            guard next.slotIndex(of: device.persistentID) == nil,
                  !next.cleared.contains(device.persistentID),
                  let free = next.slots.firstIndex(where: { $0 == nil })
            else { continue }
            next.slots[free] = SlottedDevice(device)
        }
        return next
    }

    /// Frees a slot. A device cleared while connected isn't auto-assigned
    /// again until it reconnects.
    mutating func clear(slot: Int, isConnected: Bool) {
        guard slots.indices.contains(slot), let slotted = slots[slot] else { return }
        slots[slot] = nil
        if isConnected { cleared.insert(slotted.persistentID) }
    }

    /// Puts a device into a slot. If it already occupies another slot the two
    /// swap; otherwise the previous occupant (if any) becomes unslotted.
    mutating func place(_ device: SlottedDevice, in slot: Int) {
        guard slots.indices.contains(slot) else { return }
        cleared.remove(device.persistentID)
        if let from = slotIndex(of: device.persistentID) {
            slots.swapAt(from, slot)
        } else {
            slots[slot] = device
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
}

@MainActor
final class SlotStore: ObservableObject {
    static let shared = SlotStore()
    private static let defaultsKey = "deviceSlots"

    @Published private(set) var state: SlotState {
        didSet {
            guard state != oldValue, let data = try? JSONEncoder().encode(state) else { return }
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(SlotState.self, from: data),
           decoded.slots.count == SlotState.count {
            state = decoded
        } else {
            state = SlotState()
        }
    }

    func reconcile(with devices: [Device]) {
        let next = state.reconciled(with: devices)
        if next != state { state = next }
    }

    func clear(slot: Int) {
        guard let id = state.slots[slot]?.persistentID else { return }
        state.clear(slot: slot, isConnected: DeviceStore.shared.connectedDevice(persistentID: id) != nil)
    }

    /// Handles a drag payload (a persistent ID) dropped on a slot: either a
    /// slotted device moving/swapping, or an unslotted connected device.
    func drop(persistentID: String, on slot: Int) {
        if let from = state.slotIndex(of: persistentID), let slotted = state.slots[from] {
            state.place(slotted, in: slot)
        } else if let device = DeviceStore.shared.devices.first(where: { $0.persistentID == persistentID }) {
            state.place(SlottedDevice(device), in: slot)
        }
    }

    /// Dropping a slotted device outside the slots removes it from its slot.
    func unslot(persistentID: String) {
        guard let slot = state.slotIndex(of: persistentID) else { return }
        clear(slot: slot)
    }
}
