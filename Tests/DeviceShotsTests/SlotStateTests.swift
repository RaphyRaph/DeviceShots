import XCTest
@testable import DeviceShots

final class SlotStateTests: XCTestCase {
    private let pixel = Device(id: "adb-1", name: "Pixel 10 Pro", detail: "Android 17", kind: .android, available: true)
    private let iphone = Device(id: "IPHONE", name: "iPhone", detail: "iOS 27", kind: .ios, available: true)
    private let ipad = Device(id: "IPAD", name: "iPad Pro", detail: "iOS 27", kind: .ios, available: true, isTablet: true)
    private let simulator = Device(id: "SIM", name: "iPhone 17", detail: "iOS 27", kind: .simulator, available: true)

    private func ids(_ state: SlotState) -> [String?] {
        state.slots.map { $0?.persistentID }
    }

    func testNewPhysicalDevicesTakeFirstFreeSlotsAndSimulatorsDoNot() {
        let state = SlotState().reconciled(with: [pixel, simulator, iphone])

        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", nil, nil, nil, nil])
    }

    func testDisconnectedDeviceKeepsItsSlotAndReconnectsIntoIt() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state = state.reconciled(with: [iphone])            // Pixel unplugged
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", nil, nil, nil, nil])

        state = state.reconciled(with: [iphone, ipad])      // new device while Pixel is away
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", "IPAD", nil, nil, nil])

        state = state.reconciled(with: [ipad, iphone, pixel]) // Pixel back, discovery order changed
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", "IPAD", nil, nil, nil])
    }

    func testReconcileRefreshesRememberedName() {
        var state = SlotState().reconciled(with: [iphone])
        let renamed = Device(id: "IPHONE", name: "Raph's iPhone", detail: "iOS 27", kind: .ios, available: true)

        state = state.reconciled(with: [renamed])

        XCTAssertEqual(state.slots[0]?.name, "Raph's iPhone")
    }

    func testClearingConnectedDeviceKeepsItOutUntilItReconnects() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state.clear(slot: 0, isConnected: true)
        state = state.reconciled(with: [pixel, iphone])
        XCTAssertEqual(ids(state), [nil, "IPHONE", nil, nil, nil, nil], "still connected: not re-assigned")

        state = state.reconciled(with: [iphone])            // unplugged
        state = state.reconciled(with: [pixel, iphone])     // plugged back in
        XCTAssertEqual(ids(state), ["adb-1", "IPHONE", nil, nil, nil, nil])
    }

    func testClearingDisconnectedDeviceFreesSlotForNextDevice() {
        var state = SlotState().reconciled(with: [pixel, iphone])
        state = state.reconciled(with: [iphone])            // Pixel away

        state.clear(slot: 0, isConnected: false)
        state = state.reconciled(with: [iphone, ipad])

        XCTAssertEqual(ids(state), ["IPAD", "IPHONE", nil, nil, nil, nil])
    }

    func testMovingOntoOccupiedSlotSwaps() {
        var state = SlotState().reconciled(with: [pixel, iphone])

        state.place(state.slots[0]!, in: 1)

        XCTAssertEqual(ids(state), ["IPHONE", "adb-1", nil, nil, nil, nil])
    }

    func testMovingOntoEmptySlotLeavesOldSlotEmpty() {
        var state = SlotState().reconciled(with: [pixel])

        state.place(state.slots[0]!, in: 4)

        XCTAssertEqual(ids(state), [nil, nil, nil, nil, "adb-1", nil])
    }

    func testPlacingUnslottedDeviceDisplacesOccupantWhichThenTakesFreeSlot() {
        var state = SlotState().reconciled(with: [pixel, simulator])

        state.place(SlottedDevice(simulator), in: 0)
        XCTAssertEqual(ids(state), ["SIM", nil, nil, nil, nil, nil])

        state = state.reconciled(with: [pixel, simulator])
        XCTAssertEqual(ids(state), ["SIM", "adb-1", nil, nil, nil, nil])
    }

    func testManuallyPlacingClearedDeviceReArmsIt() {
        var state = SlotState().reconciled(with: [pixel])
        state.clear(slot: 0, isConnected: true)

        state.place(SlottedDevice(pixel), in: 2)

        XCTAssertFalse(state.cleared.contains("adb-1"))
        XCTAssertEqual(ids(state), [nil, nil, "adb-1", nil, nil, nil])
    }

    func testDevicesBeyondSixSlotsStayUnslotted() {
        let devices = (1...7).map {
            Device(id: "D\($0)", name: "Device \($0)", detail: "", kind: .ios, available: true)
        }

        let state = SlotState().reconciled(with: devices)

        XCTAssertEqual(ids(state), ["D1", "D2", "D3", "D4", "D5", "D6"])
        XCTAssertNil(state.slotIndex(of: "D7"))
    }

    func testUnavailableDevicesAreNotAutoAssigned() {
        let unauthorized = Device(id: "adb-2", name: "adb-2", detail: "", kind: .android, available: false)

        let state = SlotState().reconciled(with: [unauthorized])

        XCTAssertEqual(ids(state), [nil, nil, nil, nil, nil, nil])
    }

    func testMenuOrderIsSlotOrderThenUnslotted() {
        var state = SlotState().reconciled(with: [pixel, iphone])
        state.place(state.slots[0]!, in: 1)                // iPhone first, Pixel second

        let ordered = state.ordered([pixel, simulator, iphone])

        XCTAssertEqual(ordered.map(\.device.id), ["IPHONE", "adb-1", "SIM"])
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

        XCTAssertEqual(ids(state), ["IPHONE", "57131FDCH0016C", nil, nil, nil, nil])
    }

    func testParseAndroidProps() {
        let props = DeviceDiscovery.parseAndroidProps("17\n57131FDCH0016C\n")
        XCTAssertEqual(props.version, "17")
        XCTAssertEqual(props.hardwareSerial, "57131FDCH0016C")

        let noSerial = DeviceDiscovery.parseAndroidProps("17\n\n")
        XCTAssertNil(noSerial.hardwareSerial)
    }

    func testStateRoundTripsThroughJSON() throws {
        var state = SlotState().reconciled(with: [pixel, ipad])
        state.clear(slot: 0, isConnected: true)

        let decoded = try JSONDecoder().decode(SlotState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded, state)
    }
}
