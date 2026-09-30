import XCTest
@testable import DeviceShotsKit

/// Records a real Android device through `VideoRecorder`. Skipped unless
/// DEVICESHOTS_RECORD_SERIAL is set to an `adb devices` serial:
///   DEVICESHOTS_RECORD_SERIAL=<serial> swift test --filter RecordingHardwareTests
@MainActor
final class RecordingHardwareTests: XCTestCase {
    func testRecordsPlayableVideoFromAndroid() async throws {
        guard let serial = ProcessInfo.processInfo.environment["DEVICESHOTS_RECORD_SERIAL"] else {
            throw XCTSkip("set DEVICESHOTS_RECORD_SERIAL to run")
        }
        let device = Device(id: serial, name: "Test Pixel", detail: "", kind: .android, available: true,
                            hardwareSerial: serial)
        let recorder = VideoRecorder.shared
        recorder.start(device)
        XCTAssertTrue(recorder.isRecording(device))
        try await Task.sleep(for: .seconds(8))
        recorder.stop(device)
        for _ in 0..<200 where recorder.isRecording(device) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(recorder.isRecording(device))
        XCTAssertEqual(DeviceStore.shared.status[device.id]?.isError, false,
                       DeviceStore.shared.status[device.id]?.message ?? "no status")
        let files = try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("Test Pixel") }
        XCTAssertEqual(files.count, 1)
        for file in files {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(file)
            XCTAssertTrue(MP4.isComplete(url))
            try? FileManager.default.removeItem(at: url)
        }
    }
}
