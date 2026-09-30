import AppKit
import SwiftUI

/// What one recording pill shows. `isStopping` swaps Stop for "Saving…" while
/// the video is finalized (Android pulls the file off the device first).
@MainActor
final class RecordingHUDModel: ObservableObject {
    let startedAt: Date
    let deviceName: String
    let onStop: () -> Void
    @Published var isStopping = false
    /// Only named when several devices record at once.
    @Published var showsName = false

    init(startedAt: Date, deviceName: String, onStop: @escaping () -> Void) {
        self.startedAt = startedAt
        self.deviceName = deviceName
        self.onStop = onStop
    }
}

/// The black capsule shown at the top of the screen while recording:
/// a red dot, a running counter, and a Stop action.
struct RecordingPill: View {
    @ObservedObject var model: RecordingHUDModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 8, height: 8)
            if model.showsName {
                Text(model.deviceName)
                    .lineLimit(1)
            }
            TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                Text(Self.format(context.date.timeIntervalSince(model.startedAt)))
                    .monospacedDigit()
            }
            if model.isStopping {
                Text("Saving…")
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Button(action: model.onStop) {
                    Text("Stop")
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording \(model.deviceName)")
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(.black))
        .fixedSize()
    }

    /// 0:07, 12:34, 1:02:03
    static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Owns one pill panel per recording, stacked from the top of the screen.
/// Non-activating so clicking Stop doesn't pull focus from the frontmost app.
@MainActor
final class RecordingHUD {
    static let shared = RecordingHUD()

    private struct Entry {
        let model: RecordingHUDModel
        let panel: NSPanel
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    func show(deviceID: String, deviceName: String, startedAt: Date, onStop: @escaping () -> Void) {
        hide(deviceID: deviceID)
        let model = RecordingHUDModel(startedAt: startedAt, deviceName: deviceName, onStop: onStop)
        let host = NSHostingView(rootView: RecordingPill(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)

        let panel = NSPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        // Fade in; the hosting view keeps the pill's own size.
        panel.alphaValue = 0

        entries[deviceID] = Entry(model: model, panel: panel)
        order.append(deviceID)
        layout()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func markStopping(deviceID: String) {
        entries[deviceID]?.model.isStopping = true
        resize(deviceID)
    }

    func hide(deviceID: String) {
        guard let entry = entries.removeValue(forKey: deviceID) else { return }
        order.removeAll { $0 == deviceID }
        let panel = entry.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        layout()
    }

    func hideAll() {
        for id in order { hide(deviceID: id) }
    }

    private func resize(_ deviceID: String) {
        guard let entry = entries[deviceID], let host = entry.panel.contentView as? NSHostingView<RecordingPill> else { return }
        host.frame.size = host.fittingSize
        entry.panel.setContentSize(host.fittingSize)
        layout()
    }

    private func layout() {
        let named = order.count > 1
        for id in order {
            guard let entry = entries[id] else { continue }
            if entry.model.showsName != named {
                entry.model.showsName = named
                if let host = entry.panel.contentView as? NSHostingView<RecordingPill> {
                    host.layoutSubtreeIfNeeded()
                    host.frame.size = host.fittingSize
                    entry.panel.setContentSize(host.fittingSize)
                }
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        var top = visible.maxY - 16
        for id in order {
            guard let panel = entries[id]?.panel else { continue }
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
            top -= size.height + 8
        }
    }
}
