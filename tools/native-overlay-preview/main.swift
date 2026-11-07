import AppKit

/// Runs the production overlay without microphone, speech models, or hotkeys,
/// so the glass and layout can be judged over real windows in seconds.
@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayPanel()
    private var statusItem: NSStatusItem?
    private var demo: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Glass Preview"
        let menu = NSMenu()
        for (title, action) in [
            ("Show Listening", #selector(showListening)),
            ("Show Short Text", #selector(showShort)),
            ("Show Long Text", #selector(showLong)),
            ("Play Dictation", #selector(playDictation)),
            ("Hide Preview", #selector(hidePreview)),
            ("Quit Glass Preview", #selector(quitPreview)),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item

        let args = CommandLine.arguments
        // Liveness checks: a window sliding behind the pill (--moving-window) or
        // a bar animating inside one (--moving-bg). With --bg-only, run that in
        // a second copy so the backdrop comes from another process.
        if args.contains("--moving-bg") { showMovingBackground() }
        if args.contains("--moving-window") { showMovingWindow() }
        if args.contains("--bg-only") { return }
        if args.contains("--long") { showLong() }
        else if args.contains("--listening") { showListening() }
        else if args.contains("--play") { playDictation() }
        else { showShort() }
        if args.contains("--dump") {
            // Backdrop state on first show and again after a resize.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.dumpGlass() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.showLong() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.dumpGlass() }
        }
    }

    @objc private func showListening() {
        demo?.cancel()
        overlay.show()
    }

    @objc private func showShort() {
        demo?.cancel()
        overlay.show()
        overlay.update(committed: "Let's grab lunch at noon", volatile: "tomorrow")
    }

    @objc private func showLong() {
        demo?.cancel()
        overlay.show()
        overlay.update(
            committed: "Inspect the windows behind this pill. The text should stay legible while the background changes.",
            volatile: "Try switching apps, light and dark windows, and Mission Control."
        )
    }

    /// The real state sequence: listening, partials, waiting, settle, hide.
    @objc private func playDictation() {
        demo?.cancel()
        demo = Task { @MainActor in
            let words = "so I was thinking we could move the standup to ten thirty since half the team is remote on fridays".split(separator: " ")
            overlay.show()
            try? await Task.sleep(for: .milliseconds(700))
            var committed: [Substring] = []
            for (i, word) in words.enumerated() {
                guard !Task.isCancelled else { return }
                if i >= 2 { committed.append(words[i - 2]) }
                let volatile = words[max(0, i - 1)...i].joined(separator: " ")
                overlay.update(committed: committed.joined(separator: " "), volatile: volatile)
                try? await Task.sleep(for: .milliseconds(160))
                _ = word
            }
            overlay.waiting()
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await overlay.settle("So I was thinking we could move the standup to 10:30, since half the team is remote on Fridays.")
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            overlay.hide()
        }
    }

    @objc private func hidePreview() {
        demo?.cancel()
        overlay.hideImmediately()
    }

    @objc private func quitPreview() { NSApp.terminate(nil) }

    // MARK: - Probe

    private func dumpGlass() {
        let keys = ["windowServerAware", "allowsInPlaceFiltering", "groupName", "scale", "captureOnly", "enabled"]
        func walk(_ layer: CALayer, _ depth: Int) {
            var line = String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.frame)"
            for key in keys where layer.responds(to: NSSelectorFromString(key)) {
                line += " \(key)=\(String(describing: layer.value(forKey: key)))"
            }
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
            for child in layer.sublayers ?? [] { walk(child, depth + 1) }
        }
        for window in NSApp.windows where window.contentView is NSGlassEffectView {
            FileHandle.standardError.write("window level=\(window.level.rawValue) flatten=\(String(describing: window.value(forKey: "shouldAutoFlattenLayerTree")))\n".data(using: .utf8)!)
            if let layer = window.contentView?.layer { walk(layer, 0) }
        }
    }

    private var background: NSPanel?

    private var mover: Timer?

    /// A whole window sliding behind the pill, like dragging a window.
    private func showMovingWindow() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let panel = NSPanel(contentRect: NSRect(x: v.midX - 400, y: v.minY + 60, width: 160, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .systemOrange
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        background = panel
        var t = 0.0
        mover = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                t += 1.0 / 60
                let x = v.midX - 400 + (sin(t * .pi) + 1) / 2 * 640
                panel.setFrameOrigin(NSPoint(x: x, y: v.minY + 60))
            }
        }
    }

    /// A separate window under the pill with a bar sweeping across it, to
    /// check that the glass samples the live backdrop rather than a snapshot.
    private func showMovingBackground() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let frame = NSRect(x: v.midX - 400, y: v.minY + 60, width: 800, height: 200)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .black
        panel.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let bar = CALayer()
        bar.backgroundColor = NSColor.systemOrange.cgColor
        bar.frame = NSRect(x: 0, y: 0, width: 120, height: frame.height)
        view.layer?.addSublayer(bar)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = 60
        sweep.toValue = frame.width - 60
        sweep.duration = 2
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        bar.add(sweep, forKey: "sweep")
        panel.contentView = view
        panel.orderFrontRegardless()
        background = panel
    }
}

let delegate = MainActor.assumeIsolated { PreviewDelegate() }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}
