import AppKit
import QuartzCore

/// Top-of-screen capturing pill (black capsule, system font). Non-activating so
/// Capture & Paste keeps focus in the frontmost app.
@MainActor
final class CaptureHUD {
    static let shared = CaptureHUD()

    private var panel: NSPanel?
    private var pill: NSView?
    private var label: NSTextField?
    private var isVisible = false

    func show(for device: Device) {
        let panel = ensurePanel()
        label?.stringValue = title(for: device)
        layoutPill()
        position(panel)

        guard let pill else {
            panel.orderFrontRegardless()
            return
        }

        if isVisible {
            panel.orderFrontRegardless()
            return
        }
        isVisible = true

        pill.layer?.removeAllAnimations()
        pill.alphaValue = 0
        setPillScale(0.72)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        animate(scaleFrom: 0.72, scaleTo: 1, alphaFrom: 0, alphaTo: 1, duration: 0.28)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false

        animate(scaleFrom: 1, scaleTo: 0.86, alphaFrom: 1, alphaTo: 0, duration: 0.2) { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel?.orderOut(nil)
            self.pill?.layer?.removeAllAnimations()
            self.setPillScale(1)
            self.pill?.alphaValue = 1
        }
    }

    func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        pill = nil
        label = nil
        isVisible = false
    }

    private func title(for device: Device) -> String {
        switch device.kind {
        case .android:
            return "Capturing Android..."
        case .ios:
            return device.isTablet ? "Capturing iPad..." : "Capturing iPhone..."
        case .simulator:
            return "Capturing \(device.name)..."
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let label = NSTextField(labelWithString: "Capturing…")
        label.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail

        // Frame-based pill so Core Animation scale never fights Auto Layout.
        let pill = NSView(frame: .zero)
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.cgColor
        // Capsule: radius is set to height/2 in layoutPill().
        pill.layer?.cornerCurve = .circular
        pill.addSubview(label)

        let host = NSView(frame: .zero)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        // Allow the grow animation to draw within the host; panel is sized to the
        // final (unscaled) pill, and we only scale ≤ 1 so nothing is clipped.
        host.layer?.masksToBounds = false
        host.addSubview(pill)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 28),
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
        panel.ignoresMouseEvents = true
        panel.contentView = host

        self.panel = panel
        self.pill = pill
        self.label = label
        layoutPill()
        return panel
    }

    private func layoutPill() {
        guard let panel, let host = panel.contentView, let pill, let label else { return }

        // Figma Tag: px 8, py 2, 14pt / 20pt line-height
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 2
        let lineHeight: CGFloat = 20

        label.sizeToFit()
        let textSize = label.bounds.size
        let pillSize = NSSize(
            width: max(ceil(textSize.width) + horizontalPadding * 2, 120),
            height: max(lineHeight + verticalPadding * 2, 24)
        )

        label.frame = NSRect(
            x: horizontalPadding,
            y: (pillSize.height - lineHeight) / 2,
            width: pillSize.width - horizontalPadding * 2,
            height: lineHeight
        )
        pill.frame = NSRect(origin: .zero, size: pillSize)
        host.frame = pill.frame
        panel.setContentSize(pillSize)
        // Fully rounded ends (capsule), not a fixed 16pt radius.
        pill.layer?.cornerRadius = pillSize.height / 2

        // Pivot grow/shrink from the top-center (under the menu bar / notch).
        // AppKit layer y increases upward, so top = anchorPoint.y 1.
        if let layer = pill.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.bounds = CGRect(origin: .zero, size: pillSize)
            layer.position = CGPoint(x: pillSize.width / 2, y: pillSize.height)
            layer.transform = CATransform3DIdentity
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // Sit fully inside the visible frame (below the menu bar / notch).
        let y = visible.maxY - size.height - 16
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func setPillScale(_ scale: CGFloat) {
        pill?.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    private func animate(
        scaleFrom: CGFloat,
        scaleTo: CGFloat,
        alphaFrom: CGFloat,
        alphaTo: CGFloat,
        duration: CFTimeInterval,
        completion: (() -> Void)? = nil
    ) {
        guard let pill else {
            completion?()
            return
        }

        pill.alphaValue = alphaFrom
        setPillScale(scaleFrom)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = scaleFrom
        scale.toValue = scaleTo
        scale.duration = duration
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0))
        CATransaction.setCompletionBlock {
            DispatchQueue.main.async { completion?() }
        }
        pill.layer?.add(scale, forKey: "hudScale")
        setPillScale(scaleTo)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1.0)
            pill.animator().alphaValue = alphaTo
        }
        CATransaction.commit()
    }
}
