import SwiftUI
import AppKit

/// One instruction: a short action, how to do it, and optionally a command
/// to copy. `detail` may use **bold** for words the user looks for on screen.
struct SetupStep {
    var title: String
    var detail: String?
    var command: String?
    /// Already satisfied (e.g. the tool is installed): shown with a checkmark
    /// instead of a number.
    var isDone = false
}

/// Connection instructions shown from the menu's "Set up …" items.
struct SetupConfig {
    let title: String
    let sections: [(header: String, steps: [SetupStep])]
    let footnote: String

    static let android = androidGuide(adbInstalled: adbPath != nil)
    static let ios = iosGuide(xcodeInstalled: hasXcodeTools)

    static func androidGuide(adbInstalled: Bool) -> SetupConfig {
        SetupConfig(
            title: "Android device",
            sections: [
                ("Before you start", [
                    adbInstalled
                        ? SetupStep(title: "adb is installed", isDone: true)
                        : SetupStep(title: "Install adb",
                                    detail: "Android’s device tool. Run this in Terminal, then relaunch Device Shots:",
                                    command: "brew install android-platform-tools"),
                ]),
                ("On your Android device", [
                    SetupStep(title: "Turn on Developer options",
                              detail: "Settings → About phone → tap **Build number** 7 times."),
                    SetupStep(title: "Turn on USB debugging",
                              detail: "Settings → System → Developer options → **USB debugging**."),
                    SetupStep(title: "Connect it with a USB cable",
                              detail: "Use a data cable; charge‑only cables won’t work."),
                    SetupStep(title: "Allow USB debugging",
                              detail: "Check **Always allow from this computer**, then tap **Allow**."),
                ]),
                ("On this Mac", [
                    SetupStep(title: "Allow the accessory",
                              detail: "If asked “Allow accessory to connect?”, click **Allow**."),
                ]),
            ],
            footnote: "The device then appears in the Device Shots menu. Not showing up? Check the phone for the “Allow USB debugging?” prompt."
        )
    }

    static func iosGuide(xcodeInstalled: Bool) -> SetupConfig {
        SetupConfig(
            title: "iPhone or iPad",
            sections: [
                ("Before you start", [
                    xcodeInstalled
                        ? SetupStep(title: "Xcode is installed", isDone: true)
                        : SetupStep(title: "Install Xcode",
                                    detail: "Get it from the App Store, open it once to finish setup, then relaunch Device Shots."),
                ]),
                ("On your iPhone or iPad", [
                    SetupStep(title: "Connect it with a USB cable"),
                    SetupStep(title: "Trust this Mac",
                              detail: "Unlock the device and tap **Trust** when asked."),
                    SetupStep(title: "Turn on Developer Mode",
                              detail: "Settings → Privacy & Security → **Developer Mode**. After the restart, tap **Turn On**."),
                ]),
                ("On this Mac", [
                    SetupStep(title: "Allow the accessory",
                              detail: "If asked “Allow accessory to connect?”, click **Allow**."),
                ]),
            ],
            footnote: "The device then appears in the Device Shots menu. The first pairing can take a minute; after that it also works over Wi‑Fi on the same network."
        )
    }

    static let instructionsWidth: CGFloat = 360
}

/// Shows a setup guide in its own window. Not an alert: people follow the
/// steps on the device while reading, so it shouldn't block the app, and
/// NSAlert switches layouts depending on content height.
@MainActor
enum SetupWindow {
    private static var windows: [String: NSWindow] = [:]

    static func show(_ config: SetupConfig) {
        defer { NSApp.activate() }
        if let window = windows[config.title] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SetupWindowContent(config: config) {
            windows[config.title]?.close()
        })
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "Set up your \(config.title)"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        windows[config.title] = window
    }
}

/// Window body: the guide plus a Done button.
struct SetupWindowContent: View {
    let config: SetupConfig
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            SetupGuideView(config: config)
            Button("Done", action: onDone)
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
    }
}

/// Body of the setup alert; also used by previews and snapshots.
struct SetupGuideView: View {
    let config: SetupConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(numberedSections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 12) {
                    Text(section.header.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { _, item in
                        SetupStepRow(step: item.step, number: item.number)
                    }
                }
            }

            // Same columns as the steps: icon under the badges, text under the titles.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "info.circle")
                    .frame(width: 20)
                Text(config.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(width: SetupConfig.instructionsWidth, alignment: .leading)
        .padding(.vertical, 8)
    }

    /// Numbers run across sections and skip steps that are already done.
    private var numberedSections: [(header: String, steps: [(step: SetupStep, number: Int?)])] {
        var next = 1
        return config.sections.map { section in
            (section.header, section.steps.map { step in
                guard !step.isDone else { return (step, nil) }
                defer { next += 1 }
                return (step, next)
            })
        }
    }
}

private struct SetupStepRow: View {
    let step: SetupStep
    let number: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .fontWeight(.semibold)
                if let detail = step.detail {
                    Text((try? AttributedString(markdown: detail)) ?? AttributedString(detail))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command = step.command {
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        if let number {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(.green)
                .frame(width: 20)
        }
    }
}
