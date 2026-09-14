@testable import Mimi
import XCTest
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class DesktopGlassTests: XCTestCase {
    @MainActor
    func testCaptureDiscoveryRecoversWhenMimiIsInitiallyMissing() async throws {
        var attempts = 0
        let result = try await waitForGlassCaptureContent(retryDelay: .zero) { () async -> String? in
            attempts += 1
            return attempts < 3 ? nil : "display with Mimi excluded"
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(result, "display with Mimi excluded")
    }

    @MainActor
    func testCaptureDiscoveryRejectsLateContentAfterCancellation() async {
        // Simulate hide() cancelling startup while WindowServer is answering.
        let startup = Task { @MainActor in
            try await waitForGlassCaptureContent(retryDelay: .zero) { () async -> String? in
                withUnsafeCurrentTask { $0?.cancel() }
                return "late content"
            }
        }
        do {
            _ = try await startup.value
            XCTFail("A hidden overlay must not start capture from a late result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCaptureMappingWorksOnDisplaysAboveAndLeftOfMainDisplay() {
        for screenOrigin in [CGPoint.zero, CGPoint(x: -1600, y: 0), CGPoint(x: 200, y: 1000)] {
            let screen = CGRect(origin: screenOrigin, size: CGSize(width: 1600, height: 1000))
            let visible = CGRect(x: screen.minX, y: screen.minY + 60, width: 1600, height: 912)
            let geometry = GlassCaptureGeometry(screenFrame: screen, visibleFrame: visible)
            XCTAssertEqual(geometry.sourceRect.minY, 28)
            XCTAssertTrue(screen.contains(geometry.region))
            let overlay = CGRect(x: visible.midX - 230, y: visible.minY + 120, width: 460, height: 44)
            let origin = geometry.textureOrigin(for: overlay)
            XCTAssertEqual(origin.x, 64)
            XCTAssertEqual(origin.y + overlay.height, geometry.region.height - 64)
            // Texture top-left converts back to this overlay's screen top-left.
            XCTAssertEqual(geometry.region.minX + origin.x, overlay.minX)
            XCTAssertEqual(geometry.region.maxY - origin.y, overlay.maxY)
        }
    }

    func testCaptureEnvelopeFitsASmallDisplay() {
        let screen = CGRect(x: -300, y: -200, width: 400, height: 500)
        let geometry = GlassCaptureGeometry(screenFrame: screen, visibleFrame: screen)
        XCTAssertTrue(screen.contains(geometry.region))
        XCTAssertEqual(geometry.sourceRect.minX, 0)
        XCTAssertEqual(geometry.region.width, screen.width)
    }

    func testActualMetalShaderMapsBackgroundAndRendersTransparentCorners() throws {
        var uniforms = defaults
        uniforms.strength = 0
        uniforms.dispersion = 0
        uniforms.magnify = 0
        let pixels = try render(uniforms)
        XCTAssertEqual(pixel(pixels, x: 0, y: 0)[3], 0)
        XCTAssertEqual(pixel(pixels, x: 160, y: 50)[3], 255)
        let mapped = pixel(pixels, x: 100, y: 50)
        XCTAssertEqual(Int(mapped[2]), Int(background(x: 132, y: 114)[2]), accuracy: 1)
        XCTAssertEqual(Int(mapped[1]), Int(background(x: 132, y: 114)[1]), accuracy: 1)
    }

    func testMagnificationChangesSamplesAndNoCaptureFallbackIsTranslucent() throws {
        let lens = try render(defaults)
        var plain = defaults
        plain.strength = 0; plain.magnify = 0; plain.dispersion = 0
        let flat = try render(plain)
        XCTAssertNotEqual(pixel(lens, x: 80, y: 50), pixel(flat, x: 80, y: 50))
        XCTAssertEqual(pixel(lens, x: 160, y: 50)[3], 255)

        var fallback = defaults
        fallback.hasBackdrop = 0
        let transparent = try render(fallback)
        XCTAssertEqual(Int(pixel(transparent, x: 160, y: 50)[3]), 56, accuracy: 1)
        fallback.hasBackdrop = -1
        XCTAssertEqual(pixel(try render(fallback), x: 160, y: 50)[3], 255)

        // Optional offscreen visual QA: synthetic pixels only, no desktop capture
        // or app windows. The shipping renderer and this test share the shader.
        if let path = ProcessInfo.processInfo.environment["MIMI_GLASS_TEST_IMAGE"] {
            try writeImage(lens, path: path)
        }
    }

    private let width = 320
    private let height = 100
    private var defaults: GlassUniforms {
        GlassUniforms(size: SIMD2(320, 100), origin: SIMD2(32, 64), captureSize: SIMD2(512, 256), hasBackdrop: 1)
    }

    private func background(x: Int, y: Int) -> [UInt8] {
        [((x / 16 + y / 16) % 2 == 0) ? 210 : 40, UInt8(y), UInt8(x / 2), 255]
    }

    private func pixel(_ pixels: [UInt8], x: Int, y: Int) -> [UInt8] {
        Array(pixels[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
    }

    private func render(_ inputUniforms: GlassUniforms) throws -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let pipeline = try GlassShader.pipeline(device: device)
        XCTAssertEqual(MemoryLayout<GlassUniforms>.stride, 48)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 512, height: 256, mipmapped: false)
        inputDescriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
        let pixels = (0..<256).flatMap { y in (0..<512).flatMap { x in background(x: x, y: y) } }
        pixels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 512, 256), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 512 * 4) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var uniforms = inputUniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var result = [UInt8](repeating: 0, count: width * height * 4)
        result.withUnsafeMutableBytes { destination.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        return result
    }

    private func writeImage(_ pixels: [UInt8], path: String) throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
