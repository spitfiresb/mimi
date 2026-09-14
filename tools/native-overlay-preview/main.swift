import AppKit

/// Runs the production overlay without microphone, speech models, hotkeys,
/// or the custom screen-capture renderer. Leave it visible during Space swipes.
@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayPanel(tunesGlass: false)
    private var statusItem: NSStatusItem?
    private var tuningTimer: Timer?
    private var tuningPasses = 0
    private var originalFilters: [CALayer: [Any]] = [:]
    private var useTunedGlass = true
    private var useDeepLens = true
    private var calibrationBackground: NSPanel?
    private var transparentControl: NSPanel?
    private var backgroundTimer: Timer?
    private var backgroundIsMoving = false
    private var liveSamples: [String] = []
    private let experimentStarted = CACurrentMediaTime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Glass Preview"
        let menu = NSMenu()
        for (title, action) in [
            ("Deep Lens Test", #selector(enableDeepLens)),
            ("Previous Edge Lens", #selector(enableTunedGlass)),
            ("Original Native Glass", #selector(disableTunedGlass)),
            ("Show Numbered Grid Comparison", #selector(showCalibration)),
            ("Animate / Pause Grid Background", #selector(toggleBackgroundMotion)),
            ("Hide Grid (Keep Lens Unchanged)", #selector(hideGridKeepingLens)),
            ("Show / Hide Text (Keep Lens Size)", #selector(toggleReferenceText)),
            ("Hide Grid / Show Over Desktop", #selector(showShort)),
            ("Show Short Text", #selector(showShort)),
            ("Show Long Text", #selector(showLong)),
            ("Hide Preview", #selector(hidePreview)),
            ("Quit Glass Preview", #selector(quitPreview)),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
        if CommandLine.arguments.contains("--grid") || CommandLine.arguments.contains("--live-grid") {
            showCalibration()
            if CommandLine.arguments.contains("--live-grid") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    guard self.calibrationBackground != nil else { return }
                    self.toggleBackgroundMotion()
                }
            }
        } else {
            showShort()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.writeGlassDiagnostics()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.writeGlassDiagnostics()
        }
    }

    // Preview-only investigation of undocumented macOS 26 glass filter inputs.
    // Based on runtime inputKeys and the experiment described at:
    // https://habr.com/ru/articles/1053570/
    // These controls are not a supported API or part of the production renderer.
    @objc private func tuneGlass() {
        tuningPasses += 1
        guard useTunedGlass,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var wroteInputs = false
        let baseValues: [String: Any] = [
            "inputRefractionOpacity": 1.0,
            "inputBlurRadius": 0.0,
            "inputBlurOpacity0": 0.0,
            "inputBlurOpacity1": 0.0,
            "inputBlurOpacity2": 0.0,
            "inputBlurOpacity3": 0.0,
            "inputBlurOpacity4": 0.0,
            "inputFaceColorMatrixWhite": 1.0,
            "inputFaceColorMatrixBlack": 0.0,
            "inputFaceColorMatrixSaturation": 1.0,
            "inputFaceColorMatrixFillColor": NSColor.clear.cgColor,
        ]
        func walk(_ layer: CALayer, lensHeight: CGFloat) {
            if let filters = layer.filters {
                for (index, item) in filters.enumerated() {
                    guard let filter = item as? NSObject,
                          filter.responds(to: NSSelectorFromString("inputKeys")),
                          let keys = filter.value(forKey: "inputKeys") as? [String],
                          keys.contains("inputRefractionOpacity"),
                          filter.responds(to: NSSelectorFromString("name")),
                          let name = filter.value(forKey: "name") as? String,
                          !name.isEmpty, !name.contains(".") else { continue }
                    var desired = baseValues
                    if useDeepLens {
                        // The stock negative amount produces an edge reflection.
                        // A positive amount below the depth tests a magnifying
                        // profile. Cover the entire half-height rather than
                        // leaving an untouched band through the middle.
                        // Parameter interpretation: https://lrdcq.com/me/read.php/165.htm
                        desired["inputInnerRefractionHeight"] = lensHeight
                        desired["inputInnerRefractionAmount"] = lensHeight * 0.6
                    }
                    let presented = layer.presentation()?.filters
                    let presentedFilter = presented.flatMap { index < $0.count ? $0[index] as? NSObject : nil }
                    let presentedKeys = presentedFilter?.responds(to: NSSelectorFromString("inputKeys")) == true
                        ? (presentedFilter?.value(forKey: "inputKeys") as? [String] ?? []) : []
                    let changes = desired.filter { key, value in
                        guard keys.contains(key) else { return false }
                        let modelMatches = (filter.value(forKey: key) as? NSObject)?.isEqual(value) == true
                        let presentationMatches = !presentedKeys.contains(key)
                            || (presentedFilter?.value(forKey: key) as? NSObject)?.isEqual(value) == true
                        return !modelMatches || !presentationMatches
                    }
                    guard !changes.isEmpty else { continue }
                    if originalFilters[layer] == nil {
                        originalFilters[layer] = filters.map { ($0 as? NSCopying)?.copy(with: nil) ?? $0 }
                    }
                    // Set named filter inputs through the layer, so Core
                    // Animation tracks them as render-property changes. Merely
                    // replacing filter objects left presentation values stale.
                    for (key, value) in changes {
                        layer.setValue(value, forKeyPath: "filters.\(name).\(key)")
                    }
                    wroteInputs = true
                }
            }
            for child in layer.sublayers ?? [] { walk(child, lensHeight: lensHeight) }
        }
        for window in NSApp.windows where window.isVisible {
            if let glass = window.contentView as? NSGlassEffectView, let layer = glass.layer {
                walk(layer, lensHeight: max(1, glass.bounds.height / 2))
            }
        }
        CATransaction.commit()
        if wroteInputs { CATransaction.flush() }
        // Keep diagnostics current while switching applications; a startup
        // snapshot alone cannot detect later material resets.
        if tuningPasses.isMultiple(of: 150) { writeGlassDiagnostics() }
        if tuningPasses.isMultiple(of: 30) { sampleLiveFilters() }
    }

    private func startTuning() {
        tuningTimer?.invalidate()
        tuningTimer = nil
        guard useTunedGlass else { return }
        tuneGlass()
        // AppKit can build or replace the effect after orderFront. A timer also
        // retries when a view-bound display link doesn't tick for the inactive
        // panel. Only changed filter inputs are written, and only in this demo.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tuneGlass() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tuningTimer = timer
    }

    @objc private func enableTunedGlass() {
        restoreFilters()
        useTunedGlass = true
        useDeepLens = false
        showShort()
    }

    @objc private func enableDeepLens() {
        restoreFilters()
        useTunedGlass = true
        useDeepLens = true
        showShort()
    }

    private func restoreFilters() {
        tuningTimer?.invalidate()
        tuningTimer = nil
        for (layer, filters) in originalFilters { layer.filters = filters }
        originalFilters.removeAll()
    }

    @objc private func disableTunedGlass() {
        useTunedGlass = false
        restoreFilters()
        showShort()
    }

    private func writeGlassDiagnostics() {
        var lines = ["reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) tuningPasses=\(tuningPasses) deepLens=\(useDeepLens)"]
        func walk(_ layer: CALayer, depth: Int) {
            lines.append("\(String(repeating: " ", count: depth))\(type(of: layer)) frame=\(layer.frame) opaque=\(layer.isOpaque) opacity=\(layer.opacity)")
            for case let filter as NSObject in layer.filters ?? [] {
                guard filter.responds(to: NSSelectorFromString("inputKeys")) else { continue }
                let keys = filter.value(forKey: "inputKeys") as? [String] ?? []
                lines.append("filter=\(filter) keys=\(keys)")
                for key in keys { lines.append("  \(key)=\(String(describing: filter.value(forKey: key)))") }
            }
            for child in layer.sublayers ?? [] { walk(child, depth: depth + 1) }
        }
        for window in NSApp.windows {
            lines.append("window visible=\(window.isVisible) key=\(window.isKeyWindow) opaque=\(window.isOpaque) frame=\(window.frame) content=\(window.contentView.map { String(describing: type(of: $0)) } ?? "nil")")
            if let layer = window.contentView?.layer { walk(layer, depth: 0) }
        }
        try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "mimi-glass-diagnostics.txt", atomically: true, encoding: .utf8)
    }

    /// Model and presentation values are sampled separately: retained requested
    /// values alone don't establish what Core Animation is presenting.
    private func sampleLiveFilters() {
        let keys = ["inputRefractionOpacity", "inputInnerRefractionAmount", "inputInnerRefractionHeight", "inputBlurRadius"]
        func values(_ layer: CALayer?) -> String {
            for case let filter as NSObject in layer?.filters ?? [] {
                guard filter.responds(to: NSSelectorFromString("inputKeys")),
                      let supported = filter.value(forKey: "inputKeys") as? [String],
                      supported.contains(keys[0]) else { continue }
                return keys.map { supported.contains($0) ? "\($0)=\(filter.value(forKey: $0) ?? "nil")" : "\($0)=absent" }.joined(separator: ",")
            }
            return "none"
        }
        let elapsed = Int(CACurrentMediaTime() - experimentStarted)
        let tick = (calibrationBackground?.contentView as? CalibrationGrid)?.sourceTick ?? -1
        func walk(_ layer: CALayer) {
            let model = values(layer)
            if model != "none" {
                liveSamples.append("t=\(elapsed)s sourceTick=\(tick) moving=\(backgroundIsMoving) frame=\(layer.frame) model:[\(model)] presentation:[\(values(layer.presentation()))] animations=\(layer.animationKeys() ?? [])")
            }
            for child in layer.sublayers ?? [] { walk(child) }
        }
        for window in NSApp.windows where window.isVisible && window.contentView is NSGlassEffectView {
            if let layer = window.contentView?.layer { walk(layer) }
        }
        if liveSamples.count > 90 { liveSamples.removeFirst(liveSamples.count - 90) }
        try? liveSamples.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "mimi-glass-live.txt", atomically: true, encoding: .utf8)
    }

    /// The grid is in a separate window underneath both panels, never supplied
    /// as a texture to the effect. The dense pattern eliminates empty-page
    /// whitespace as an explanation for an apparently blank lens.
    @objc private func showCalibration() {
        restoreFilters()
        useTunedGlass = true
        useDeepLens = true
        showShort()
        guard let screen = NSScreen.main,
              let lens = NSApp.windows.first(where: { $0.isVisible && $0.contentView is NSGlassEffectView }),
              let glass = lens.contentView as? NSGlassEffectView else { return }
        let frame = NSRect(x: screen.visibleFrame.midX - 430,
                           y: screen.visibleFrame.minY + 50, width: 860, height: 240)
        let board = makeDiagnosticPanel(frame: frame, level: .floating)
        board.isOpaque = true
        board.backgroundColor = .white
        board.contentView = CalibrationGrid(frame: NSRect(origin: .zero, size: frame.size))
        calibrationBackground = board
        board.orderFrontRegardless()

        let control = makeDiagnosticPanel(
            frame: NSRect(x: frame.minX + 40, y: frame.minY + 80, width: 350, height: 52),
            level: .statusBar)
        let clear = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 52))
        clear.wantsLayer = true
        clear.layer?.backgroundColor = NSColor.clear.cgColor
        clear.layer?.cornerRadius = 22
        clear.layer?.borderWidth = 1.5
        clear.layer?.borderColor = NSColor.black.cgColor
        control.contentView = clear
        transparentControl = control
        control.orderFrontRegardless()

        // Remove all foreground text from the comparison so it cannot obscure
        // the background. Keep the same production panel and native glass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard self.calibrationBackground === board else { return }
            // Wait for the production overlay's text-resize animation to end
            // before placing it over the right-hand grid.
            glass.contentView?.subviews.forEach { $0.isHidden = true }
            lens.setFrame(NSRect(x: frame.minX + 470, y: frame.minY + 80, width: 350, height: 52), display: true)
            lens.orderFrontRegardless()
            glass.layoutSubtreeIfNeeded()
            self.startTuning()
        }
    }

    @objc private func toggleBackgroundMotion() {
        guard let grid = calibrationBackground?.contentView as? CalibrationGrid else { return }
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        backgroundIsMoving.toggle()
        grid.isMoving = backgroundIsMoving
        grid.needsDisplay = true
        guard backgroundIsMoving else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak grid] _ in
            MainActor.assumeIsolated { grid?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        backgroundTimer = timer
    }

    @objc private func hideGridKeepingLens() {
        // Crucially, do not call showShort or restoreFilters here. Retain the
        // exact 350x52 geometry, hidden foreground, and 26/15.6 lens settings.
        backgroundTimer?.invalidate()
        backgroundTimer = nil
        backgroundIsMoving = false
        calibrationBackground?.close()
        transparentControl?.close()
        calibrationBackground = nil
        transparentControl = nil
    }

    @objc private func toggleReferenceText() {
        for window in NSApp.windows where window.isVisible {
            guard let content = (window.contentView as? NSGlassEffectView)?.contentView else { continue }
            let hide = !(content.subviews.first?.isHidden ?? false)
            content.subviews.forEach { $0.isHidden = hide }
        }
    }

    private func makeDiagnosticPanel(frame: NSRect, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func hideCalibration() {
        hideGridKeepingLens()
        for window in NSApp.windows {
            (window.contentView as? NSGlassEffectView)?.contentView?.subviews.forEach { $0.isHidden = false }
        }
    }

    @objc private func showShort() {
        hideCalibration()
        let title = useTunedGlass ? (useDeepLens ? "Clear lens preview" : "Previous edge lens") : "Original native glass"
        overlay.show(message: title)
        overlay.setLocked(true)
        overlay.update(committed: title, volatile: "")
        startTuning()
    }

    @objc private func showLong() {
        hideCalibration()
        overlay.show()
        overlay.setLocked(true)
        overlay.update(
            committed: "Inspect the windows behind this pill. The foreground text should stay sharp while the background moves.",
            volatile: "Try switching apps, swiping between desktops, and opening Mission Control."
        )
        startTuning()
    }

    @objc private func hidePreview() {
        hideCalibration()
        tuningTimer?.invalidate()
        tuningTimer = nil
        overlay.hideImmediately()
    }
    @objc private func quitPreview() { NSApp.terminate(nil) }
}

@MainActor
private final class CalibrationGrid: NSView {
    private var frames = 0
    var isMoving = false
    var sourceTick: Int { frames / 30 }
    func advance() {
        frames += 1
        needsDisplay = true
    }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let titleStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        ("LEFT: plain transparency" as NSString).draw(at: NSPoint(x: 40, y: 205), withAttributes: titleStyle)
        ("RIGHT: experimental native lens" as NSString).draw(at: NSPoint(x: 470, y: 205), withAttributes: titleStyle)
        ("\(isMoving ? "MOVING" : "PAUSED") · source tick \(sourceTick) · same 350×52 lens as the earlier comparison" as NSString)
            .draw(at: NSPoint(x: 40, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
        for originX: CGFloat in [40, 470] {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: originX, y: 40, width: 350, height: 128)).addClip()
            for row in -1..<9 {
                for col in 0..<14 {
                    let offset = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? CGFloat(0) : CGFloat(frames % 60) * 16 / 60
                    let rect = NSRect(x: originX + CGFloat(col) * 25, y: 40 + CGFloat(row) * 16 + offset, width: 25, height: 16)
                    ((row + col).isMultiple(of: 2)
                        ? NSColor(calibratedRed: 0.65, green: 0.87, blue: 1, alpha: 1)
                        : NSColor(calibratedRed: 1, green: 0.84, blue: 0.6, alpha: 1)).setFill()
                    rect.fill()
                    let number = ((row + 10 + sourceTick) % 10) * 10 + col % 10
                    (String(format: "%02d", number) as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 1), withAttributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.black,
                    ])
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        ("Glass Preview → Hide Grid (Keep Lens Unchanged) tests this exact lens over other apps." as NSString)
            .draw(at: NSPoint(x: 40, y: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }
}

let delegate = MainActor.assumeIsolated { PreviewDelegate() }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}
