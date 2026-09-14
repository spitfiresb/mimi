import CoreGraphics

/// AppKit screen coordinates are bottom-up; captured texture coordinates are
/// display-local and top-down. Keep the conversion independent of display order.
struct GlassCaptureGeometry: Equatable {
    let screenFrame: CGRect
    let region: CGRect

    init(screenFrame: CGRect, visibleFrame: CGRect, maxOverlayWidth: CGFloat = 460,
         bottomInset: CGFloat = 120, bleed: CGFloat = 64) {
        self.screenFrame = screenFrame
        let width = min(maxOverlayWidth + bleed * 2, screenFrame.width)
        let x = min(max(visibleFrame.midX - width / 2, screenFrame.minX), screenFrame.maxX - width)
        let bottom = max(screenFrame.minY, visibleFrame.minY + bottomInset - bleed)
        // A stable envelope accommodates growing transcripts without racing
        // SCStream configuration changes against in-flight frames.
        region = CGRect(x: x, y: bottom, width: width,
                        height: max(1, visibleFrame.maxY - bottom)).intersection(screenFrame)
    }

    var sourceRect: CGRect {
        CGRect(x: region.minX - screenFrame.minX, y: screenFrame.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    func textureOrigin(for overlayFrame: CGRect) -> CGPoint {
        CGPoint(x: overlayFrame.minX - region.minX, y: region.maxY - overlayFrame.maxY)
    }
}
