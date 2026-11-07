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
    private let glass: LiveGlassView
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
            .canJoinAllSpaces, .canJoinAllApplications, .stationary,
            .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.appearance = nil
        // Stock regular Liquid Glass — the same material as Notification Center
        // pills. WindowServer composites and blurs the live backdrop; no private
        // filter tuning and no screen capture.
        glass = LiveGlassView(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 22

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

        // The supported content slot keeps the transcript above the glass and
        // lets label colors adapt to the backdrop, as system glass text does.
        let content = NSView()
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
        glass.setLive(true)
        startPulse()
    }

    /// A new recording stays invisible until its ready callback reveals it.
    func hideImmediately() {
        hideGeneration += 1
        stopPulse()
        panel.orderOut(nil)
        glass.setLive(false)
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
                self.glass.setLive(false)
                self.panel.alphaValue = 1
            }
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
                .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
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

/// Stock glass in Mimi's panel samples a snapshot of whatever was behind it,
/// so windows dragged underneath never show through. Two undocumented
/// switches keep it live, as system glass is: the backdrop layer reads other
/// apps' windows through WindowServer (`windowServerAware`), and the window
/// never flattens its layer tree into a stale copy.
///
/// AppKit turns `windowServerAware` back off on nearly every layout, and
/// replaces the backdrop layer (with the switch off) when the glass resizes.
/// Fixing that up afterwards on a timer let the backdrop flip between modes
/// between frames, which read as a stutter. Instead, while visible:
/// - a main run-loop observer runs just before Core Animation commits each
///   frame and switches on any new or reset backdrop layer, and
/// - each backdrop layer is observed with KVO, so a reset made during the
///   commit itself is reverted synchronously, in the same transaction.
/// Either way a frame never renders with the switch off.
///
/// Selectors are checked first; a macOS without them falls back to stock glass.
/// Set `MIMI_GLASS_DEBUG=1` to log each correction.
/// https://oskargroth.com/blog/reverse-engineering-nsvisualeffectview
final class LiveGlassView: NSGlassEffectView {
    private static let key = "windowServerAware"
    private static let debug = ProcessInfo.processInfo.environment["MIMI_GLASS_DEBUG"] != nil
    /// Held strongly so no observed layer can deallocate while registered.
    private var observed: [CALayer] = []

    private var beforeCommit: CFRunLoopObserver?

    override func layout() {
        super.layout()
        keepBackdropLive()
    }

    deinit {
        if let beforeCommit { CFRunLoopRemoveObserver(CFRunLoopGetMain(), beforeCommit, .commonModes) }
        for layer in observed { layer.removeObserver(self, forKeyPath: Self.key) }
    }

    /// Call on show and hide; nothing runs while the panel is hidden.
    func setLive(_ live: Bool) {
        if let beforeCommit {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), beforeCommit, .commonModes)
            self.beforeCommit = nil
        }
        guard live else { return }
        keepBackdropLive()
        // Core Animation commits in a before-waiting observer at order 2000000;
        // running just ahead of it covers every frame's layer changes.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_000 - 1) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.keepBackdropLive() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        beforeCommit = observer
    }

    func keepBackdropLive() {
        if let window, window.responds(to: NSSelectorFromString("_setShouldAutoFlattenLayerTree:")),
           (window.value(forKey: "shouldAutoFlattenLayerTree") as? Bool) != false {
            Self.note("flatten")
            window.setValue(false, forKey: "shouldAutoFlattenLayerTree")
        }
        var backdrops: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.responds(to: NSSelectorFromString("setWindowServerAware:")) { backdrops.append(layer) }
            layer.sublayers?.forEach(walk)
        }
        layer.map(walk)
        // AppKit can replace the glass layers on resize; follow the live ones.
        for old in observed where !backdrops.contains(where: { $0 === old }) {
            old.removeObserver(self, forKeyPath: Self.key)
        }
        for new in backdrops where !observed.contains(where: { $0 === new }) {
            new.addObserver(self, forKeyPath: Self.key, options: [.new], context: nil)
        }
        observed = backdrops
        backdrops.forEach(Self.enforce)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.key, let layer = object as? CALayer else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        Self.enforce(layer)
    }

    private static func enforce(_ layer: CALayer) {
        guard (layer.value(forKey: key) as? Bool) != true else { return }
        note(key)
        layer.setValue(true, forKey: key)
    }

    private static func note(_ what: String) {
        guard debug else { return }
        FileHandle.standardError.write("glass: re-enabled \(what) at \(CACurrentMediaTime())\n".data(using: .utf8)!)
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
