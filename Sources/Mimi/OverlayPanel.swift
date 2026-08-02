import AppKit

/// A floating, non-activating panel showing what Mimi is hearing.
///
/// It must never become key or main — if it took focus, the synthesized ⌘V
/// would land here instead of in the app the user was typing into.
@MainActor
final class OverlayPanel {
    private let panel: NonActivatingPanel
    private let label: NSTextField

    private static let size = NSSize(width: 560, height: 60)
    private static let bottomInset: CGFloat = 140
    private static let padding: CGFloat = 18

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        let glyph = NSImageView(frame: NSRect(x: Self.padding, y: 19, width: 22, height: 22))
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .systemRed
        glyph.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)

        let labelX = Self.padding + 22 + 12
        label = NSTextField(labelWithString: "")
        label.frame = NSRect(
            x: labelX, y: 0,
            width: Self.size.width - labelX - Self.padding,
            height: Self.size.height
        )
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .left
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        label.cell?.usesSingleLineMode = true
        label.autoresizingMask = [.width]

        blur.addSubview(glyph)
        blur.addSubview(label)
        panel.contentView = blur
    }

    func show(_ text: String) {
        update(text)
        reposition()
        panel.orderFrontRegardless()
    }

    func update(_ text: String) {
        label.stringValue = text
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Self.size.width / 2,
            y: visible.minY + Self.bottomInset
        )
        panel.setFrameOrigin(origin)
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
