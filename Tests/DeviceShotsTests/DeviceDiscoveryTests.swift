import XCTest
@testable import DeviceShots

final class DeviceDiscoveryTests: XCTestCase {
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
        XCTAssertEqual(devices[0].kind, .ios)
        XCTAssertTrue(devices[0].available)
        XCTAssertFalse(devices[0].isTablet)
    }
}
