import AppKit

/// A floating, non-activating panel showing what Mimi is hearing.
///
/// The text is the interface: volatile words arrive dimmed and darken as the
/// recognizer commits them, so the utterance visibly solidifies. When the
/// formatting pass lands, the sentence crossfades into its cleaned form before
/// being pasted. The panel hugs its content — it grows with the text instead of
/// living in a fixed gray slab.
///
/// It must never become key or main — if it took focus, the synthesized ⌘V
/// would land here instead of in the app the user was typing into.
@MainActor
final class OverlayPanel {
    private let panel: NonActivatingPanel
    private let blur: NSVisualEffectView
    private let glyph: NSImageView
    private let label: NSTextField

    private static let minWidth: CGFloat = 220
    private static let maxWidth: CGFloat = 460
    private static let hPad: CGFloat = 16
    private static let vPad: CGFloat = 12
    private static let glyphWidth: CGFloat = 18
    private static let glyphGap: CGFloat = 10
    private static let cornerRadius: CGFloat = 14
    private static let bottomInset: CGFloat = 120
    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: 44),
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
        // The HUD material is dark regardless of system theme; pin the whole
        // panel to dark so semantic colors resolve against it. In light mode,
        // labelColor was resolving to black before vibrancy kicked in — a black
        // flash on every commit.
        panel.appearance = NSAppearance(named: .darkAqua)

        blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        // Rounding the layer leaves the material's square corners peeking out
        // behind the mask. maskImage clips the material itself.
        blur.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        glyph = NSImageView()
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .secondaryLabelColor
        glyph.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Listening"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        glyph.wantsLayer = true

        label = NSTextField(wrappingLabelWithString: "")
        label.font = Self.font
        label.textColor = .labelColor
        // No line cap — the pill grows with the utterance. Seeing everything you
        // said beats a tidy box.
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.wantsLayer = true

        blur.addSubview(glyph)
        blur.addSubview(label)
        panel.contentView = blur
    }

    // MARK: - States

    func show() {
        render(committed: "", volatile: "Listening…", animated: false)
        panel.orderFrontRegardless()
        startPulse()
    }

    /// Committed text solidifies to full label color; the volatile tail stays
    /// dimmed until the recognizer commits it.
    func update(committed: String, volatile: String) {
        render(committed: committed, volatile: volatile, animated: true)
    }

    /// Everything dims while the final pass runs.
    func waiting() {
        stopPulse()
        let current = label.attributedStringValue.string
        render(committed: "", volatile: current, animated: true)
    }

    /// The cleaned sentence replaces the raw one, holds a beat so the change
    /// reads, then the panel slips away. Returns after the hold.
    func settle(_ text: String) async {
        stopPulse()
        render(committed: text, volatile: "", animated: true)
        try? await Task.sleep(for: .milliseconds(450))
    }

    func hide() {
        stopPulse()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
        }
    }

    // MARK: - Rendering

    private func render(committed: String, volatile: String, animated: Bool) {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: committed, attributes: [
            .font: Self.font, .foregroundColor: NSColor.labelColor,
        ]))
        if !volatile.isEmpty {
            let joined = committed.isEmpty || committed.hasSuffix(" ") ? volatile : " " + volatile
            text.append(NSAttributedString(string: joined, attributes: [
                .font: Self.font, .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }

        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            label.layer?.add(fade, forKey: "textFade")
        }
        label.attributedStringValue = text
        layout(for: text)
    }

    /// The panel hugs the text: width and height follow the content, animated so
    /// growth reads as the text advancing rather than the box jumping.
    private func layout(for text: NSAttributedString) {
        let textLeft = Self.hPad + Self.glyphWidth + Self.glyphGap
        let maxTextWidth = Self.maxWidth - textLeft - Self.hPad

        let bounds = text.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: Self.font))
        // Uncapped height, but never past the visible screen.
        let maxTextHeight = (NSScreen.main?.visibleFrame.height ?? 800) - Self.bottomInset - 40
        let textHeight = min(ceil(bounds.height), maxTextHeight)
        let textWidth = min(ceil(bounds.width), maxTextWidth)

        let width = max(Self.minWidth, textLeft + textWidth + Self.hPad)
        let height = textHeight + 2 * Self.vPad

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + Self.bottomInset,
            width: width,
            height: height
        )

        label.frame = NSRect(x: textLeft, y: Self.vPad, width: textWidth, height: textHeight)
        glyph.frame = NSRect(
            x: Self.hPad,
            y: height - Self.vPad - lineHeight + (lineHeight - 14) / 2,
            width: Self.glyphWidth,
            height: 14
        )

        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: - Pulse

    private func startPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glyph.layer?.add(pulse, forKey: "pulse")
    }

    private func stopPulse() {
        glyph.layer?.removeAnimation(forKey: "pulse")
    }

    // MARK: -

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
