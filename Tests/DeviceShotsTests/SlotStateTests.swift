import XCTest
@testable import DeviceShotsKit

final class SlotStateTests: XCTestCase {
    private let pixel = Device(id: "adb-1", name: "Pixel 10 Pro", detail: "Android 17", kind: .android, available: true)
    private let iphone = Device(id: "IPHONE", name: "iPhone", detail: "iOS 27", kind: .ios, available: true)
    private let ipad = Device(id: "IPAD", name: "iPad Pro", detail: "iOS 27", kind: .ios, available: true, isTablet: true)
    private let simulator = Device(id: "SIM", name: "iPhone 17", detail: "iOS 27", kind: .simulator, available: true)
    private let cmd1 = Shortcut(keyCode: 18, modifiers: NSEvent.ModifierFlags.command.rawValue)
    private let cmd2 = Shortcut(keyCode: 19, modifiers: NSEvent.ModifierFlags.command.rawValue)

    private func ids(_ state: SlotState) -> [String?] {
        state.slots.map { $0.device?.persistentID }
    }

    func testNewDevicesGetNewSlotsIncludingBootedSimulators() {
        let state = SlotState().reconciled(with: [pixel, simulator, iphone])

        XCTAssertEqual(ids(state), ["adb-1", "SIM", "IPHONE"])
    }

    func testNoSlotLimit() {
        let devices = (1...8).map { Device(id: "D\($0)", name: "D\($0)", detail: "", kind: .ios, available: true) }

        XCTAssertEqual(SlotState().reconciled(with: devices).slots.count, 8)
    }

    func testDisconnectedDeviceKeepsItsSlotAndReconnectsIntoIt() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state = state.reconciled(with: [iphone])                 // Pixel unplugged
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE"])

        state = state.reconciled(with: [iphone, ipad])           // new device while Pixel is away
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", "IPAD"])

        state = state.reconciled(with: [ipad, iphone, pixel])    // back, discovery order changed
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", "IPAD"])
    }

    func testReconcileRefreshesRememberedName() {
        var state = SlotState().reconciled(with: [iphone])
        let renamed = Device(id: "IPHONE", name: "Raph's iPhone", detail: "iOS 27", kind: .ios, available: true)

        state = state.reconciled(with: [renamed])

        XCTAssertEqual(state.slots[0].device?.name, "Raph's iPhone")
    }

    func testClearingSlotWithoutShortcutsDeletesIt() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state.clear(slot: 0, isConnected: false)

        XCTAssertEqual(ids(state), ["IPHONE"])
    }

    func testClearingSlotWithShortcutsKeepsItEmpty() {
        var state = SlotState().reconciled(with: [pixel, iphone])
        state.setShortcut(cmd1, kind: .capture, slot: 0)

        state.clear(slot: 0, isConnected: false)

        XCTAssertEqual(ids(state), [nil, "IPHONE"])
        XCTAssertEqual(state.shortcut(.capture, slot: 0), cmd1)
    }

    func testNewDeviceTakesShortcutOnlySlotAndInheritsShortcuts() {
        var state = SlotState()
        state.setShortcut(cmd1, kind: .paste, slot: 0)          // recorded in the spare row
        XCTAssertEqual(ids(state), [nil])

        state = state.reconciled(with: [ipad])

        XCTAssertEqual(ids(state), ["IPAD"])
        XCTAssertEqual(state.shortcut(.paste, slot: 0), cmd1)
    }

    func testRemovingLastShortcutOfEmptySlotDeletesIt() {
        var state = SlotState()
        state.setShortcut(cmd1, kind: .capture, slot: 0)
        state.setShortcut(cmd2, kind: .paste, slot: 0)

        state.setShortcut(nil, kind: .capture, slot: 0)
        XCTAssertEqual(state.slots.count, 1, "still has a paste shortcut")

        state.setShortcut(nil, kind: .paste, slot: 0)
        XCTAssertTrue(state.slots.isEmpty)
    }

    func testClearingSpareRowShortcutIsNoOp() {
        var state = SlotState().reconciled(with: [pixel])

        state.setShortcut(nil, kind: .capture, slot: 1)

        XCTAssertEqual(ids(state), ["adb-1"])
    }

    func testClearingConnectedDeviceKeepsItOutUntilItReconnects() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state.clear(slot: 0, isConnected: true)
        state = state.reconciled(with: [pixel, iphone])
        XCTAssertEqual(ids(state), ["IPHONE"], "still connected: not re-assigned")

        state = state.reconciled(with: [iphone])                 // unplugged
        state = state.reconciled(with: [pixel, iphone])          // plugged back in
        XCTAssertEqual(ids(state), ["IPHONE", "adb-1"])
    }

    func testMovingOntoOccupiedSlotSwapsDevicesButNotShortcuts() {
        var state = SlotState().reconciled(with: [pixel, iphone])
        state.setShortcut(cmd1, kind: .capture, slot: 0)
        state.setShortcut(cmd2, kind: .capture, slot: 1)

        state.move(from: 0, to: 1)

        XCTAssertEqual(ids(state), ["IPHONE", "adb-1"])
        XCTAssertEqual(state.shortcut(.capture, slot: 0), cmd1)
        XCTAssertEqual(state.shortcut(.capture, slot: 1), cmd2)
    }

    func testMovingToSpareRowDeletesTheEmptiedSlot() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state.move(from: 0, to: 2)                               // spare row

        XCTAssertEqual(ids(state), ["IPHONE", "adb-1"])
    }

    func testMovingToSpareRowKeepsSourceSlotIfItHasShortcuts() {
        var state = SlotState().reconciled(with: [pixel, iphone])
        state.setShortcut(cmd1, kind: .capture, slot: 0)

        state.move(from: 0, to: 2)

        XCTAssertEqual(ids(state), [nil, "IPHONE", "adb-1"])
        XCTAssertEqual(state.shortcut(.capture, slot: 0), cmd1)
    }

    func testRecordShortcutIsRefusedOnDevicesThatCannotRecord() {
        var state = SlotState().reconciled(with: [iphone, pixel])   // slot 0 iPhone, slot 1 Pixel

        state.setShortcut(cmd1, kind: .record, slot: 0)
        state.setShortcut(cmd2, kind: .record, slot: 1)

        XCTAssertNil(state.shortcut(.record, slot: 0))
        XCTAssertEqual(state.shortcut(.record, slot: 1), cmd2)
    }

    func testMovingUnrecordableDeviceIntoSlotClearsItsRecordShortcut() {
        var state = SlotState().reconciled(with: [pixel, iphone])   // slot 0 Pixel, slot 1 iPhone
        state.setShortcut(cmd1, kind: .record, slot: 0)
        state.setShortcut(cmd2, kind: .capture, slot: 0)

        state.move(from: 1, to: 0)                                   // iPhone takes Pixel's slot

        XCTAssertEqual(ids(state), ["IPHONE", "adb-1"])
        XCTAssertNil(state.shortcut(.record, slot: 0))
        XCTAssertEqual(state.shortcut(.capture, slot: 0), cmd2)      // other shortcuts stay
    }

    func testRecordShortcutSurvivesMovingRecordableDevices() {
        var state = SlotState().reconciled(with: [pixel, simulator])
        state.setShortcut(cmd1, kind: .record, slot: 0)

        state.move(from: 1, to: 0)

        XCTAssertEqual(ids(state), ["SIM", "adb-1"])
        XCTAssertEqual(state.shortcut(.record, slot: 0), cmd1)
    }

    func testUnrecordableDeviceAutoAssignedToSlotDropsItsRecordShortcut() {
        var state = SlotState()
        state.setShortcut(cmd1, kind: .record, slot: 0)              // shortcut-only slot

        state = state.reconciled(with: [iphone])

        XCTAssertEqual(ids(state), ["IPHONE"])
        XCTAssertNil(state.shortcut(.record, slot: 0))
    }

    func testRecordShortcutCountsAsUsedAndRoundTrips() throws {
        var state = SlotState()
        state.setShortcut(cmd1, kind: .record, slot: 0)
        XCTAssertEqual(state.slots.count, 1)

        let decoded = try JSONDecoder().decode(SlotState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)

        state.setShortcut(nil, kind: .record, slot: 0)
        XCTAssertTrue(state.slots.isEmpty)
    }

    func testStateSavedBeforeRecordShortcutsStillDecodes() throws {
        let legacy = #"{"slots":[{"id":"\#(UUID().uuidString)","capture":null}],"cleared":[]}"#
        let decoded = try JSONDecoder().decode(SlotState.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.slots.count, 1)
        XCTAssertNil(decoded.slots[0].record)
    }

    func testUnavailableDevicesAreNotAutoAssigned() {
        let unauthorized = Device(id: "adb-2", name: "adb-2", detail: "", kind: .android, available: false)

        XCTAssertTrue(SlotState().reconciled(with: [unauthorized]).slots.isEmpty)
    }

    func testMenuOrderIsSlotOrderThenUnslotted() {
        var state = SlotState().reconciled(with: [pixel, iphone])
        state.move(from: 0, to: 1)                               // iPhone first, Pixel second

        let extra = Device(id: "EXTRA", name: "Extra", detail: "", kind: .ios, available: true)
        let ordered = state.ordered([pixel, extra, iphone])

        XCTAssertEqual(ordered.map(\.device.id), ["IPHONE", "adb-1", "EXTRA"])
        XCTAssertEqual(ordered.map(\.slot), [0, 1, nil])
    }

    func testAndroidSlotSurvivesChangingAdbSerial() {
        let overUSB = Device(id: "57131FDCH0016C", name: "Pixel", detail: "", kind: .android,
                             available: true, hardwareSerial: "57131FDCH0016C")
        let overWiFi = Device(id: "192.168.1.20:41234", name: "Pixel", detail: "", kind: .android,
                              available: true, hardwareSerial: "57131FDCH0016C")

        var state = SlotState().reconciled(with: [iphone, overUSB])
        state = state.reconciled(with: [iphone])
        state = state.reconciled(with: [iphone, overWiFi])

        XCTAssertEqual(ids(state), ["IPHONE", "57131FDCH0016C"])
    }

    func testParseAndroidProps() {
        let props = DeviceDiscovery.parseAndroidProps("17\n57131FDCH0016C\n")
        XCTAssertEqual(props.version, "17")
        XCTAssertEqual(props.hardwareSerial, "57131FDCH0016C")

        XCTAssertNil(DeviceDiscovery.parseAndroidProps("17\n\n").hardwareSerial)
    }

    func testStateRoundTripsThroughJSON() throws {
        var state = SlotState().reconciled(with: [pixel, ipad])
        state.setShortcut(cmd1, kind: .paste, slot: 1)
        state.clear(slot: 0, isConnected: true)

        let decoded = try JSONDecoder().decode(SlotState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
    }

    private func box(_ type: String, size: Int) -> Data {
        var data = Data([UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)])
        data.append(Data(type.utf8))
        data.append(Data(count: size - 8))
        return data
    }

    func testMP4CompletenessNeedsMoovBox() throws {
        let dir = FileManager.default.temporaryDirectory
        let good = dir.appendingPathComponent("good-\(UUID().uuidString).mp4")
        let cutOff = dir.appendingPathComponent("cut-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: good); try? FileManager.default.removeItem(at: cutOff) }

        try (box("ftyp", size: 24) + box("mdat", size: 100) + box("moov", size: 40)).write(to: good)
        // A killed screenrecord leaves media data with a bogus size and no index.
        var truncated = box("ftyp", size: 24) + box("free", size: 32)
        truncated.append(Data([0x3F, 0x3F, 0x3F, 0x3F]) + Data("mdat".utf8) + Data(count: 64))
        try truncated.write(to: cutOff)

        XCTAssertTrue(MP4.isComplete(good))
        XCTAssertFalse(MP4.isComplete(cutOff))
    }
}
