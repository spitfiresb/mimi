@testable import Mimi
import AppKit
import XCTest

final class NativeGlassTests: XCTestCase {
    @MainActor
    func testUnattachedGlassDoesNotStartPolling() {
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 350, height: 52))
        let tuner = NativeGlassTuner(view: glass)
        tuner.start()
        XCTAssertFalse(tuner.isRunning)
    }

    /// Exercises the actual AppKit presentation layer, including the propagation
    /// failure that the model-only checks in the prototype missed. This checks
    /// rendering configuration and lifecycle, not optical appearance.
    @MainActor
    func testPresentationTracksResizeAndPollingStopsAfterHide() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Requires a window server") }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            throw XCTSkip("System requests an opaque material")
        }
        let window = NSPanel(contentRect: NSRect(x: 20, y: 20, width: 350, height: 52),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 350, height: 52))
        glass.style = .clear
        glass.cornerRadius = 22
        glass.contentView = NSView(frame: glass.bounds)
        window.contentView = glass
        let tuner = NativeGlassTuner(view: glass)
        defer { tuner.stop(); window.close() }
        window.orderFrontRegardless()
        let originalFlatten = window.value(forKey: "shouldAutoFlattenLayerTree") as? NSNumber
        tuner.start()
        XCTAssertTrue(tuner.isRunning)

        for _ in 0..<60 {
            if tuner.presentationMatches { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(tuner.presentationMatches, "Requested values must reach the presentation layer")

        // Let the window sit longer than the usual flattening delay. These
        // assertions cover compositing configuration, not captured pixels.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual((window.value(forKey: "shouldAutoFlattenLayerTree") as? NSNumber)?.boolValue, false)
        func backdrops(_ layer: CALayer) -> [CALayer] {
            let own = layer.responds(to: NSSelectorFromString("windowServerAware")) ? [layer] : []
            return own + (layer.sublayers ?? []).flatMap { backdrops($0) }
        }
        let layers = glass.layer.map { backdrops($0) } ?? []
        XCTAssertFalse(layers.isEmpty)
        for layer in layers {
            XCTAssertEqual((layer.value(forKey: "windowServerAware") as? NSNumber)?.boolValue, true)
            XCTAssertEqual((layer.value(forKey: "allowsInPlaceFiltering") as? NSNumber)?.boolValue, false)
        }

        // AppKit may rewrite these while changing material state. The next
        // refresh must repair the backdrop even when filter inputs still match.
        window.setValue(true, forKey: "shouldAutoFlattenLayerTree")
        for layer in layers { layer.setValue(false, forKey: "windowServerAware") }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual((window.value(forKey: "shouldAutoFlattenLayerTree") as? NSNumber)?.boolValue, false)
        for layer in layers {
            XCTAssertEqual((layer.value(forKey: "windowServerAware") as? NSNumber)?.boolValue, true)
        }

        window.setContentSize(NSSize(width: 430, height: 86))
        glass.layoutSubtreeIfNeeded()
        // Allow at least one refresh before checking the new geometry.
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<60 {
            if tuner.presentationMatches { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(glass.bounds.height, 86)
        XCTAssertTrue(tuner.presentationMatches, "Presentation must follow the growing transcript panel")

        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(tuner.isRunning, "A hidden panel must not keep a background timer running")
        XCTAssertFalse(tuner.presentationMatches)
        XCTAssertEqual(window.value(forKey: "shouldAutoFlattenLayerTree") as? NSNumber, originalFlatten)
        for layer in layers {
            XCTAssertEqual((layer.value(forKey: "windowServerAware") as? NSNumber)?.boolValue, false)
        }
    }
}
