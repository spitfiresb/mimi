import AppKit
import ScreenCaptureKit
import os

/// WindowServer's list can lag a newly shown panel. Keep discovery alive until
/// it contains a safe exclusion, but never start capture after the panel hides.
@MainActor
func waitForGlassCaptureContent<Content>(
    retryDelay: Duration = .milliseconds(300),
    query: () async throws -> Content?
) async throws -> Content {
    while true {
        try Task.checkCancellation()
        let content = try await query()
        try Task.checkCancellation()
        if let content { return content }
        try await Task.sleep(for: retryDelay)
    }
}

/// Owns only the visible overlay's video stream. Audio is explicitly disabled.
/// Frame delivery and lifecycle changes are serialized on the main thread.
@MainActor
final class DesktopGlassCapture {
    private static let log = Logger(subsystem: "com.zainsaeed.mimi", category: "glass")
    private var stream: SCStream?
    private var output: GlassStreamOutput?
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var displayID: CGDirectDisplayID?
    private var geometry: GlassCaptureGeometry?
    var onFrame: ((CVPixelBuffer, GlassCaptureGeometry) -> Void)?
    var onUnavailable: (() -> Void)?

    func start(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let id = number.uint32Value
        let target = GlassCaptureGeometry(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        if displayID == id, geometry == target, stream != nil || startTask != nil { return }
        stop()
        guard CGPreflightScreenCaptureAccess() else {
            Self.log.notice("Glass is transparent without refraction: Screen Recording permission is needed")
            return
        }
        displayID = id
        geometry = target
        let token = generation
        let scale = screen.backingScaleFactor
        startTask = Task { [weak self] in
            guard let self else { return }
            var startingStream: SCStream?
            defer { if self.generation == token { self.startTask = nil } }
            do {
                var reportedWait = false
                let (display, ownApps) = try await waitForGlassCaptureContent { () async throws -> (SCDisplay, [SCRunningApplication])? in
                    // Include ordered-out windows: Mimi is a menu-bar app whose
                    // only regular window may just be entering the compositor.
                    let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    let ownApps = available.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    if let display = available.displays.first(where: { $0.displayID == id }), !ownApps.isEmpty {
                        return (display, ownApps)
                    }
                    if !reportedWait {
                        Self.log.notice("Waiting for desktop capture content and Mimi exclusion; will retry while visible")
                        reportedWait = true
                    }
                    return nil
                }
                guard !Task.isCancelled, self.generation == token else { return }
                // Exclude the entire process, including future overlay windows.
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = target.sourceRect
                config.width = max(1, Int((target.region.width * scale).rounded()))
                config.height = max(1, Int((target.region.height * scale).rounded()))
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.showsCursor = false
                config.capturesAudio = false
                config.captureMicrophone = false
                let output = GlassStreamOutput(
                    frame: { [weak self] buffer in
                        guard let self, self.generation == token else { return }
                        self.onFrame?(buffer, target)
                    },
                    unavailable: { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.stop()
                    }
                )
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                startingStream = stream
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
                guard !Task.isCancelled, self.generation == token else { return }
                try await stream.startCapture()
                guard !Task.isCancelled, self.generation == token else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.output = output
                Self.log.notice("Desktop lens capture started (\(config.width)x\(config.height), max 30 fps)")
            } catch {
                if let startingStream { try? await startingStream.stopCapture() }
                guard !Task.isCancelled, self.generation == token else { return }
                Self.log.error("Desktop lens capture unavailable: \(error.localizedDescription)")
                self.onUnavailable?()
            }
        }
    }

    func stop() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        displayID = nil
        geometry = nil
        onUnavailable?()
        let previous = stream
        let retainedOutput = output
        stream = nil
        output = nil
        if let previous {
            Task {
                try? await previous.stopCapture()
                _ = retainedOutput // retain callbacks until the stream is stopped
                Self.log.notice("Desktop lens capture stopped")
            }
        }
    }
}

private final class GlassStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let frame: @MainActor (CVPixelBuffer) -> Void
    let unavailable: @MainActor () -> Void

    init(frame: @escaping @MainActor (CVPixelBuffer) -> Void, unavailable: @escaping @MainActor () -> Void) {
        self.frame = frame
        self.unavailable = unavailable
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = info.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        // This callback is registered on DispatchQueue.main.
        MainActor.assumeIsolated {
            switch status {
            case .complete:
                if let buffer = sampleBuffer.imageBuffer { frame(buffer) }
            case .blank, .suspended, .stopped:
                unavailable()
            default: break // idle frames retain the last unchanged desktop
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in unavailable() }
    }
}
