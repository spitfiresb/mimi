import AppKit
import Metal
import QuartzCore
import os

/// Read-only owners retained by a GPU completion handler. Neither buffer is
/// accessed or mutated by that handler; it only extends the IOSurface lifetime.
private struct GlassFrameLifetime: @unchecked Sendable {
    let buffer: CVPixelBuffer?
    let texture: CVMetalTexture?
}

struct GlassUniforms {
    var size: SIMD2<Float>
    var origin: SIMD2<Float>
    var captureSize: SIMD2<Float>
    var radius: Float = 22
    var strength: Float = 12
    var dispersion: Float = 0.7
    var magnify: Float = 0.12
    var rimWidth: Float = 0.55
    var hasBackdrop: Float = 0
}

/// Compiles the checked-in source, never an opaque upstream metallib.
enum GlassShader {
    static func pipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        guard let url = Bundle.main.url(forResource: "DesktopGlass", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "DesktopGlass", withExtension: "metal", subdirectory: "Shaders") else {
            throw NSError(domain: "Mimi.Glass", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing desktop glass shader"])
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

@MainActor
final class DesktopGlassView: NSView {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "glass")
    private let capture = DesktopGlassCapture()
    private let metal = CAMetalLayer()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var cache: CVMetalTextureCache?
    private var texture: MTLTexture?
    private var emptyTexture: MTLTexture?
    private var backingBuffer: CVPixelBuffer?
    private var backingTexture: CVMetalTexture?
    private var geometry: GlassCaptureGeometry?
    private var isRunning = false
    private var drawing = false
    private var pendingDraw = false
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // GPU unavailable: retain readable, genuinely translucent UI.
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 0.22).cgColor
        layer?.cornerRadius = 22
        if let device = MTLCreateSystemDefaultDevice() {
            do {
                pipeline = try GlassShader.pipeline(device: device)
                queue = device.makeCommandQueue()
                CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
                descriptor.usage = .shaderRead
                emptyTexture = device.makeTexture(descriptor: descriptor)
                var zero: UInt32 = 0
                emptyTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
                metal.device = device
                metal.pixelFormat = .bgra8Unorm
                metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
                metal.isOpaque = false
                metal.framebufferOnly = true
                metal.maximumDrawableCount = 2
                layer?.addSublayer(metal)
                layer?.backgroundColor = NSColor.clear.cgColor
            } catch {
                Self.log.error("Custom glass shader failed: \(error.localizedDescription)")
            }
        }
        capture.onFrame = { [weak self] buffer, region in self?.receive(buffer, region: region) }
        capture.onUnavailable = { [weak self] in self?.clearBackdrop() }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.refreshCapture()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCapture()
                self?.drawGlass()
            }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers + windowObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        guard let window else { stop(); return }
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needsLayout = true
                    if self.isRunning { self.refreshCapture() }
                    self.drawGlass()
                }
            })
        }
    }

    func start() {
        isRunning = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        refreshCapture()
        drawGlass()
    }

    func stop() {
        isRunning = false
        capture.stop()
    }

    private func refreshCapture() {
        guard isRunning, pipeline != nil, let screen = window?.screen,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else {
            capture.stop()
            return
        }
        capture.start(screen: screen)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit()
        if isRunning { refreshCapture() }
        drawGlass()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    private func receive(_ buffer: CVPixelBuffer, region: GlassCaptureGeometry) {
        guard isRunning, let cache else { return }
        var wrapper: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
                                                             CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &wrapper)
        guard result == kCVReturnSuccess, let wrapper, let image = CVMetalTextureGetTexture(wrapper) else {
            clearBackdrop()
            return
        }
        backingBuffer = buffer
        backingTexture = wrapper
        texture = image
        geometry = region
        drawGlass()
    }

    private func clearBackdrop() {
        texture = nil
        backingBuffer = nil
        backingTexture = nil
        geometry = nil
        drawGlass()
    }

    private func drawGlass() {
        guard window?.isVisible == true, let queue, let pipeline, let image = texture ?? emptyTexture,
              bounds.width > 0, bounds.height > 0 else { return }
        if drawing { pendingDraw = true; return }
        guard let drawable = metal.nextDrawable(), let command = queue.makeCommandBuffer() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let origin = geometry?.textureOrigin(for: window?.frame ?? .zero) ?? .zero
        let captureSize = geometry?.region.size ?? CGSize(width: 1, height: 1)
        var uniforms = GlassUniforms(size: SIMD2(Float(bounds.width), Float(bounds.height)),
                                     origin: SIMD2(Float(origin.x), Float(origin.y)),
                                     captureSize: SIMD2(Float(captureSize.width), Float(captureSize.height)),
                                     hasBackdrop: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? -1 : (texture == nil ? 0 : 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlassUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        drawing = true
        pendingDraw = false
        // Hold the IOSurface owners until the GPU finishes reading them.
        let lifetime = GlassFrameLifetime(buffer: backingBuffer, texture: backingTexture)
        command.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(lifetime) {}
            Task { @MainActor in
                guard let self else { return }
                self.drawing = false
                if self.pendingDraw { self.drawGlass() }
            }
        }
        command.present(drawable)
        command.commit()
    }
}
