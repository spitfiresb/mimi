import AppKit

/// Mimi's brand mark: an ink circle with the bunny cut out of it.
/// Geometry matches Resources/Brand/mimi-mark-mono.svg (200×200 units).
enum MimiMark {
    /// Menu-bar template image: opaque circle, transparent bunny, eyes kept.
    /// AppKit tints templates for light/dark menu bars and highlight states.
    static let menuBarImage: NSImage = makeTemplate(points: 18)

    static func makeTemplate(points: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: ctx, scale: rect.width / 200)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mimi"
        return image
    }

    /// Draws the mark into a y-down context.
    static func draw(in ctx: CGContext, scale: CGFloat) {
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 192, height: 192))

        // Punch the bunny out of the circle.
        ctx.setBlendMode(.clear)
        ellipse(ctx, cx: 80, cy: 48, rx: 13, ry: 32, degrees: -12)
        ellipse(ctx, cx: 122, cy: 48, rx: 13, ry: 32, degrees: 24)
        ellipse(ctx, cx: 100, cy: 100, rx: 48, ry: 40)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 70, y: 126))
        body.addCurve(to: CGPoint(x: 66, y: 204), control1: CGPoint(x: 66, y: 150), control2: CGPoint(x: 64, y: 176))
        body.addLine(to: CGPoint(x: 134, y: 204))
        body.addCurve(to: CGPoint(x: 130, y: 126), control1: CGPoint(x: 136, y: 176), control2: CGPoint(x: 134, y: 150))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: 130, y: 171, width: 22, height: 22))

        // The eyes stay solid.
        ctx.setBlendMode(.normal)
        ellipse(ctx, cx: 84, cy: 100, rx: 7, ry: 9)
        ellipse(ctx, cx: 116, cy: 100, rx: 7, ry: 9)
        ctx.restoreGState()
    }

    private static func ellipse(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, degrees: CGFloat = 0) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: degrees * .pi / 180)
        ctx.fillEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        ctx.restoreGState()
    }
}
