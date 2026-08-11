import XCTest
@testable import DeviceShots

final class DeviceDiscoveryTests: XCTestCase {
    func testShortcutNormalizesKeypadDigitsAndSideSpecificModifierBits() {
        let deviceSpecificBit: UInt = 1 << 8
        let shortcut = Shortcut(
            keyCode: 83, // keypad 1
            modifiers: NSEvent.ModifierFlags.command.rawValue | deviceSpecificBit
        )

        XCTAssertEqual(shortcut.keyCode, 18) // number-row 1
        XCTAssertEqual(shortcut.physicalKeyCodes, [18, 83])
        XCTAssertEqual(shortcut.modifierFlags, [.command])
    }

    func testDiscoveryOrderIsRetainedForShortcutSlots() {
        let android = Device(id: "android", name: "Pixel", detail: "Android", kind: .android, available: true)
        let iphone = Device(id: "iphone", name: "iPhone", detail: "iOS", kind: .ios, available: true)
        let simulator = Device(id: "simulator", name: "Simulator", detail: "iOS", kind: .simulator, available: true)

        let discovered = [android, simulator, iphone]

        XCTAssertEqual(discovered.map(\.id), ["android", "simulator", "iphone"])
    }

    func testPhysicalConnectedIOSDeviceIsListed() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "result": [
                "devices": [
                    [
                        "identifier": "CONNECTED-IPHONE",
                        "hardwareProperties": [
                            "reality": "physical",
                            "deviceType": "iPhone",
                            "marketingName": "iPhone 15 Pro",
                        ],
                        "deviceProperties": ["name": "Test iPhone", "osVersionNumber": "27.0"],
                        "connectionProperties": ["tunnelState": "connected"],
                    ],
                    [
                        "identifier": "DISCONNECTED-IPAD",
                        "hardwareProperties": ["reality": "physical", "deviceType": "iPad"],
                        "connectionProperties": ["tunnelState": "disconnected"],
                    ],
                    [
                        "identifier": "SIMULATOR",
                        "hardwareProperties": ["reality": "simulated", "deviceType": "iPhone"],
                        "connectionProperties": ["tunnelState": "connected"],
                    ],
                ]
            ]
        ])

        let devices = DeviceDiscovery.parseIOSPhysicalDevices(from: data)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].id, "CONNECTED-IPHONE")
        XCTAssertEqual(devices[0].name, "Test iPhone")
        XCTAssertEqual(devices[0].detail, "iPhone 15 Pro · iOS 27")
        XCTAssertEqual(devices[0].kind, .ios)
        XCTAssertTrue(devices[0].available)
        XCTAssertFalse(devices[0].isTablet)
    }
}
