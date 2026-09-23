import XCTest
import SwiftUI
@testable import DeviceShotsKit

/// Renders every Settings and setup-guide state to PNGs (light and dark).
/// Skipped unless SNAPSHOT_DIR is set; run via ./snapshots.sh.
@MainActor
final class SnapshotTests: XCTestCase {
    private var outputDir: URL!

    override func setUp() async throws {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["SNAPSHOT_DIR"].map(URL.init(fileURLWithPath:)),
                                "set SNAPSHOT_DIR (use ./snapshots.sh)")
        outputDir = dir
    }

    override func invokeTest() {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else { return }
        super.invokeTest()
    }

    func testShortcuts() throws {
        try snapshot("shortcuts-devices", size: CGSize(width: 640, height: 420)) {
            ShortcutSlotsList(slots: Fixtures.slots, connectedIDs: Fixtures.connectedIDs)
        }
        try snapshot("shortcuts-grip-hover", size: CGSize(width: 640, height: 420)) {
            ShortcutSlotsList(slots: Fixtures.slots, connectedIDs: Fixtures.connectedIDs, forceHoverSlot: 1)
        }
        try snapshot("shortcuts-no-devices", size: CGSize(width: 640, height: 200)) {
            ShortcutSlotsList(slots: [], connectedIDs: [])
        }
    }

    func testCapture() throws {
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: Prefs.saveToFolder) }

        defaults.set(false, forKey: Prefs.saveToFolder)
        try snapshot("capture", size: CGSize(width: 640, height: 440)) { CaptureSettingsView() }

        defaults.set(true, forKey: Prefs.saveToFolder)
        try snapshot("capture-save-to-folder", size: CGSize(width: 640, height: 540)) { CaptureSettingsView() }
    }

    /// The setup window's content (guide + Done button) at its natural size.
    func testSetupWindows() throws {
        for guide in Fixtures.setupGuides {
            let view = SetupWindowContent(config: guide.config)
            try snapshot("window-\(guide.name)", size: NSHostingView(rootView: view).fittingSize) { view }
        }
    }

    // MARK: - Rendering

    private func snapshot<Content: View>(_ name: String, size: CGSize, @ViewBuilder _ content: () -> Content) throws {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: content()
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))

            try write(host, name: "\(name)-\(suffix)")
            window.orderOut(nil)
        }
    }

    private func write(_ view: NSView, name: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}
