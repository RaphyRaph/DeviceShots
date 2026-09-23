import AppKit

/// Connection instructions shown from the menu's "Set up …" items.
/// Step text may use **bold** for the words the user looks for on screen.
struct SetupConfig {
    let title: String
    /// Sections of (header, steps); steps are numbered continuously across sections.
    let sections: [(header: String, steps: [String])]
    let footnote: String

    /// First step: the Mac-side tool each platform needs. Reads as done when
    /// it's already installed.
    static func prerequisite(_ tool: String, installed: Bool, howTo: String) -> (header: String, steps: [String]) {
        ("Before you start", [installed ? "✓ **\(tool)** is installed." : howTo])
    }

    static let android = androidGuide(adbInstalled: adbPath != nil)
    static let ios = iosGuide(xcodeInstalled: hasXcodeTools)

    static func androidGuide(adbInstalled: Bool) -> SetupConfig { SetupConfig(
        title: "Android device",
        sections: [
            prerequisite("adb", installed: adbInstalled,
                         howTo: "Install **adb** (Android’s device tool) by running this in Terminal, then relaunch Device Shots:\u{2028}**brew install android-platform-tools**"),
            ("On your Android device", [
                "Turn on **Developer options**: open Settings → About phone and tap **Build number** 7 times.",
                "Turn on **USB debugging**: Settings → System → Developer options.",
                "Connect it to this Mac with a USB cable. Charge‑only cables won’t work.",
                "When “Allow USB debugging?” appears, check **Always allow from this computer** and tap **Allow**.",
            ]),
            ("On this Mac", [
                "If asked “Allow accessory to connect?”, click **Allow**.",
            ]),
        ],
        footnote: "The device then appears in the Device Shots menu. If it doesn’t, check the phone for the “Allow USB debugging?” prompt."
    ) }

    static func iosGuide(xcodeInstalled: Bool) -> SetupConfig { SetupConfig(
        title: "iPhone or iPad",
        sections: [
            prerequisite("Xcode", installed: xcodeInstalled,
                         howTo: "Install **Xcode** from the App Store, open it once to finish setup, then relaunch Device Shots."),
            ("On your iPhone or iPad", [
                "Connect it to this Mac with a USB cable.",
                "Unlock it and tap **Trust** when asked to trust this computer.",
                "Turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode. The device restarts; tap **Turn On** when it’s back.",
            ]),
            ("On this Mac", [
                "If asked “Allow accessory to connect?”, click **Allow**.",
            ]),
        ],
        footnote: "The device then appears in the Device Shots menu. The first pairing can take a minute. Afterwards it also works over Wi‑Fi on the same network."
    ) }
}

extension SetupConfig {
    /// Alert body: bold section headers, numbered steps with wrapped lines
    /// indented under the text, and inline **bold**.
    func formattedInstructions() -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()

        func paragraph(indent: CGFloat = 0, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = 3
            style.headIndent = indent
            style.tabStops = indent > 0 ? [NSTextTab(textAlignment: .left, location: indent)] : []
            return style
        }

        func append(_ markdown: String, style: NSParagraphStyle, color: NSColor = .labelColor) {
            // Split on ** so odd-numbered pieces are the bold spans.
            for (index, piece) in markdown.components(separatedBy: "**").enumerated() {
                result.append(NSAttributedString(string: piece, attributes: [
                    .font: index.isMultiple(of: 2) ? bodyFont : boldFont,
                    .foregroundColor: color,
                    .paragraphStyle: style,
                ]))
            }
            result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
        }

        var stepNumber = 0
        for (sectionIndex, section) in sections.enumerated() {
            append("**\(section.header)**", style: paragraph(spacingBefore: sectionIndex == 0 ? 0 : 10))
            for step in section.steps {
                stepNumber += 1
                append("\(stepNumber).\t\(step)", style: paragraph(indent: 18))
            }
        }
        append(footnote, style: paragraph(spacingBefore: 10), color: .secondaryLabelColor)

        // Drop the trailing newline.
        result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        return result
    }

    static let instructionsWidth: CGFloat = 340

    /// The alert's body label; also used by previews and snapshots.
    @MainActor
    func makeInstructionsLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = formattedInstructions()
        label.isSelectable = true  // so the install command can be copied
        label.preferredMaxLayoutWidth = Self.instructionsWidth
        label.frame.size = NSSize(width: Self.instructionsWidth, height: label.fittingSize.height)
        return label
    }

    @MainActor
    func showAlert() {
        let alert = NSAlert()
        alert.messageText = "Set up your \(title)"
        alert.accessoryView = makeInstructionsLabel()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
