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
    private let glass: NSGlassEffectView
    private let glassTuner: NativeGlassTuner?
    private let glyph: NSImageView
    private let label: NSTextField

    private static let minWidth: CGFloat = 350
    private static let minHeight: CGFloat = 52
    private static let maxWidth: CGFloat = 460
    private static let hPad: CGFloat = 16
    private static let vPad: CGFloat = 12
    private static let glyphWidth: CGFloat = 18
    private static let glyphGap: CGFloat = 10
    private static let bottomInset: CGFloat = 120
    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    init(tunesGlass: Bool = true) {
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
            .canJoinAllSpaces, .canJoinAllApplications, .stationary,
            .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.appearance = nil
        // Let macOS composite the live backdrop without capturing screen pixels.
        // Keep the clear material untinted so moving windows remain visible.
        glass = NSGlassEffectView(frame: .zero)
        glass.style = .clear
        glass.cornerRadius = 22
        glass.tintColor = nil
        glassTuner = tunesGlass ? NativeGlassTuner(view: glass) : nil

        glyph = NSImageView()
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = NSColor.white.withAlphaComponent(0.72)
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

        // Use the supported content slot so the transcript stays above the glass.
        let content = NonVibrantView()
        content.autoresizingMask = [.width, .height]
        content.addSubview(glyph)
        content.addSubview(label)
        glass.contentView = content
        panel.contentView = glass
    }

    // MARK: - States

    private var transcriptText = ""

    func setLocked(_ locked: Bool) {
        glyph.image = NSImage(
            systemSymbolName: locked ? "lock.fill" : "waveform",
            accessibilityDescription: locked ? "Hands-free" : "Listening"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    }

    /// Monotonic token: a show() invalidates any in-flight hide, so a fade-out
    /// completing late can never orderOut a panel that was just re-shown.
    private var hideGeneration = 0

    func show(message: String = "Listening…") {
        hideGeneration += 1
        render(committed: "", volatile: message, animated: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        glassTuner?.start()
        startPulse()
    }

    /// A new recording stays invisible until its ready callback reveals it.
    func hideImmediately() {
        hideGeneration += 1
        stopPulse()
        panel.orderOut(nil)
        glassTuner?.stop()
        panel.alphaValue = 1
    }

    /// Committed text solidifies to full label color; the volatile tail stays
    /// dimmed until the recognizer commits it.
    func update(committed: String, volatile: String) {
        render(committed: committed, volatile: volatile, animated: true)
    }

    /// Live output from the formatting pass — updates arrive many times a
    /// second, so no crossfade; the text just grows.
    func stream(_ text: String) {
        render(committed: text, volatile: "", animated: false)
    }

    /// Everything dims while the final pass runs.
    func waiting() {
        stopPulse()
        setLocked(false)
        let current = transcriptText
        // If no preview ever arrived, "Listening…" is still on screen — but the
        // recording is over, and a stall past this point would wedge the panel
        // on a state the app already left. Say what's actually happening.
        let text = (current == "Listening…" || current == "Speak now") ? "Transcribing…" : current
        render(committed: "", volatile: text, animated: true)
    }

    /// The cleaned sentence replaces the raw one, holds a beat so the change
    /// reads, then the panel slips away. Returns after the hold.
    func settle(_ text: String) async {
        stopPulse()
        render(committed: text, volatile: "", animated: true)
        // Short hold: with the cleanup streamed live, the user has already
        // watched the text form — this is a beat, not a reveal.
        try? await Task.sleep(for: .milliseconds(250))
    }

    func hide() {
        stopPulse()
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            // Animation completions arrive on the main thread.
            MainActor.assumeIsolated {
                guard generation == self.hideGeneration else { return }
                self.panel.orderOut(nil)
                self.glassTuner?.stop()
                self.panel.alphaValue = 1
            }
        }
    }

    // MARK: - Rendering

    private func render(committed: String, volatile: String, animated: Bool) {
        let text = NSMutableAttributedString()
        // Local shadow supports white type over clear glass without tinting
        // or blurring the desktop underneath the entire pill.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        text.append(NSAttributedString(string: committed, attributes: [
            .font: Self.font, .foregroundColor: NSColor.white, .shadow: shadow,
        ]))
        if !volatile.isEmpty {
            let joined = committed.isEmpty || committed.hasSuffix(" ") ? volatile : " " + volatile
            text.append(NSAttributedString(string: joined, attributes: [
                .font: Self.font, .foregroundColor: NSColor.white.withAlphaComponent(0.72), .shadow: shadow,
            ]))
        }

        transcriptText = text.string

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
        // NSTextField's cell reserves horizontal space around the glyphs.
        // Measuring glyphs alone can wrap the final word onto a clipped line.
        let textInsets: CGFloat = 4

        let bounds = text.boundingRect(
            with: NSSize(width: maxTextWidth - textInsets, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: Self.font))
        // Uncapped height, but never past the visible screen.
        let maxTextHeight = (NSScreen.main?.visibleFrame.height ?? 800) - Self.bottomInset - 40
        let textHeight = min(ceil(bounds.height), maxTextHeight)
        let textWidth = min(ceil(bounds.width) + textInsets, maxTextWidth)

        let width = max(Self.minWidth, textLeft + textWidth + Self.hPad)
        let height = max(Self.minHeight, textHeight + 2 * Self.vPad)
        let textBottom = (height - textHeight) / 2

        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + Self.bottomInset,
            width: width,
            height: height
        )

        label.frame = NSRect(x: textLeft, y: textBottom, width: textWidth, height: textHeight)
        glyph.frame = NSRect(
            x: Self.hPad,
            y: height - textBottom - lineHeight + (lineHeight - 14) / 2,
            width: Self.glyphWidth,
            height: 14
        )

        if panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
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
}

private final class NonVibrantView: NSView {
    override var allowsVibrancy: Bool { false }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
