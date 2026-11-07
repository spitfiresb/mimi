import AppKit
import XCTest
@testable import Mimi

/// The overlay's glass must keep sampling live windows: AppKit turns the
/// backdrop's `windowServerAware` off during layout, and `LiveGlassView` must
/// win every time, including after the layers are rebuilt by a resize.
@MainActor
final class LiveGlassTests: XCTestCase {
    private func backdrops(_ view: NSView) -> [CALayer] {
        func walk(_ layer: CALayer) -> [CALayer] {
            (layer.responds(to: NSSelectorFromString("setWindowServerAware:")) ? [layer] : [])
                + (layer.sublayers ?? []).flatMap(walk)
        }
        return view.layer.map(walk) ?? []
    }

    private func assertLive(_ glass: LiveGlassView, _ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        let layers = backdrops(glass)
        XCTAssertFalse(layers.isEmpty, "Expected the native glass backdrop layer", file: file, line: line)
        for layer in layers {
            XCTAssertEqual(layer.value(forKey: "windowServerAware") as? Bool, true, file: file, line: line)
        }
        XCTAssertEqual(window.value(forKey: "shouldAutoFlattenLayerTree") as? Bool, false, file: file, line: line)
    }

    func testBackdropStaysLiveThroughLayoutAndResize() async throws {
        let window = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 350, height: 52),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        let glass = LiveGlassView(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 22
        window.contentView = glass
        defer { window.close() }

        window.orderFrontRegardless()
        glass.setLive(true)
        defer { glass.setLive(false) }
        try await Task.sleep(for: .milliseconds(300))
        assertLive(glass, window)

        // A resize replaces the backdrop layer, which starts with the switch off.
        window.setContentSize(NSSize(width: 430, height: 86))
        glass.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(glass.bounds.height, 86)
        assertLive(glass, window)

        // An external reset is corrected synchronously, not on a later pass.
        for layer in backdrops(glass) {
            layer.setValue(false, forKey: "windowServerAware")
            XCTAssertEqual(layer.value(forKey: "windowServerAware") as? Bool, true)
        }
    }
}
