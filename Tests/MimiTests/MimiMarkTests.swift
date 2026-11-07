import AppKit
import XCTest
@testable import Mimi

/// The menu-bar mark must read as the brand mark: a solid circle with a
/// transparent bunny cut out of it and solid eyes inside the cut-out.
final class MimiMarkTests: XCTestCase {
    private func alpha(at point: CGPoint, in rep: NSBitmapImageRep) -> CGFloat {
        // Points are in the mark's 200-unit space, y down.
        let x = Int(point.x / 200 * CGFloat(rep.pixelsWide))
        let y = Int(point.y / 200 * CGFloat(rep.pixelsHigh))
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? -1
    }

    func testMenuBarMarkIsATemplateWithTheBunnyCutOut() throws {
        let image = MimiMark.menuBarImage
        XCTAssertTrue(image.isTemplate, "Templates follow light/dark menu bars")
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 200, height: 200))
        NSGraphicsContext.restoreGraphicsState()

        XCTAssertGreaterThan(alpha(at: CGPoint(x: 30, y: 100), in: rep), 0.9, "circle is solid")
        XCTAssertLessThan(alpha(at: CGPoint(x: 100, y: 118), in: rep), 0.1, "face is cut out")
        XCTAssertLessThan(alpha(at: CGPoint(x: 80, y: 40), in: rep), 0.1, "ear is cut out")
        XCTAssertGreaterThan(alpha(at: CGPoint(x: 84, y: 100), in: rep), 0.9, "eye stays solid")
        XCTAssertLessThan(alpha(at: CGPoint(x: 2, y: 2), in: rep), 0.1, "corner outside the circle is clear")
    }
}
