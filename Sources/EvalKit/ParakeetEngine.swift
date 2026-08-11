import Accelerate
import AVFoundation
import CoreML
import Foundation

/// The challenger: our Parakeet-TDT Core ML export, run end to end in Swift —
/// vDSP mels in, greedy TDT decode out. Mirrors tools/convert/tdt_decode.py,
/// which parity-gated this exact loop against NeMo at 99%+ agreement.
public final class ParakeetEngine: EvalEngine {
    public let name: String
    private let modelsDir: URL
    private let frontend = MelFrontend()

    private struct Meta: Codable {
        let vocab_size: Int
        let blank_id: Int
        let durations: [Int]
        let mel_dim: Int
        let pred_hidden: Int
        let pred_layers: Int
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var encoders: [Int: MLModel] = [:]
    private nonisolated(unsafe) var decoder: MLModel?
    private nonisolated(unsafe) var joint: MLModel?
    private nonisolated(unsafe) var meta: Meta?
    private nonisolated(unsafe) var tokens: [String] = []
    private let suffix: String

    /// One encoder package per fixed window (ParakeetEncoderW301 etc.); pad
    /// mels up to the smallest window that fits. Fixed shapes are what let the
    /// encoder on the ANE at all — EnumeratedShapes and RangeDim exports both
    /// crash the E5/BNNS compiler (2026-08-07).
    ///
    /// Only the 30s window is used, because the packages are ~570MB *each* and
    /// the weights dominate their size — a 301-frame encoder is no cheaper to
    /// hold than a 3001-frame one. Keeping three of them meant ~1.7GB resident
    /// on an 8GB machine, so whichever window a dictation needed had usually
    /// been evicted: measured 63.5s to load W3001, 2.6s warm, 65.6s after
    /// eviction, then an outright allocation failure that returned empty text
    /// (2026-08-11). One always-warm model costs a short utterance ~36ms of
    /// padding it didn't need and removes the eviction churn entirely. It also
    /// keeps chunk seams as rare as possible, which is the other reason not to
    /// prefer a smaller window.
    public static let windows = [3001]

    public init(modelsDir: URL, int8: Bool = true) {
        self.modelsDir = modelsDir
        self.suffix = int8 ? "-int8" : ""
        self.name = int8 ? "Parakeet-int8" : "Parakeet-fp16"
    }

    /// `MLModel.compileModel` writes a ~1.2GB `.mlmodelc` into the system temp
    /// directory on every call and never cleans it up (38GB of orphans found on
    /// 2026-08-07). Compile once into a `compiled/` cache beside the packages,
    /// invalidated by the package's modification date.
    public static func compiledURL(for package: URL) throws -> URL {
        let fm = FileManager.default
        let cacheDir = package.deletingLastPathComponent().appendingPathComponent("compiled")
        let cached = cacheDir.appendingPathComponent(
            package.deletingPathExtension().lastPathComponent + ".mlmodelc")
        let packageDate = try fm.attributesOfItem(atPath: package.path)[.modificationDate] as? Date
        if fm.fileExists(atPath: cached.path),
           let cachedDate = try? fm.attributesOfItem(atPath: cached.path)[.modificationDate] as? Date,
           let packageDate, cachedDate > packageDate {
            return cached
        }
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let temp = try MLModel.compileModel(at: package)
        if fm.fileExists(atPath: cached.path) { try fm.removeItem(at: cached) }
        try fm.moveItem(at: temp, to: cached)
        return cached
    }

    private func load(_ base: String, computeUnits: MLComputeUnits) throws -> MLModel {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        let package = modelsDir.appendingPathComponent("\(base)\(suffix).mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw EvalError.engineUnavailable("missing \(package.lastPathComponent) — run tools/convert/export.py")
        }
        return try MLModel(contentsOf: Self.compiledURL(for: package), configuration: config)
    }

    /// Fixed-window encoders run on the ANE (36ms for the 15s window vs 2.2s
    /// on GPU). Loaded on first use for their window, then kept.
    private func encoder(for window: Int) throws -> MLModel {
        if let cached = lock.withLock({ encoders[window] }) { return cached }
        let model = try load("ParakeetEncoderW\(window)", computeUnits: .cpuAndNeuralEngine)
        lock.withLock { encoders[window] = model }
        return model
    }

    public func prepare() async throws {
        // Decoder and joint stay off the ANE: the decode loop is per-token
        // round trips where dispatch overhead dominates, and it already
        // measures <300ms per utterance.
        let dec = try load("ParakeetDecoder", computeUnits: .cpuAndGPU)
        let jnt = try load("ParakeetJoint", computeUnits: .cpuAndGPU)
        let m = try JSONDecoder().decode(
            Meta.self,
            from: Data(contentsOf: modelsDir.appendingPathComponent("parakeet-meta.json"))
        )
        let toks = try String(contentsOf: modelsDir.appendingPathComponent("tokens.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        lock.withLock {
            decoder = dec; joint = jnt; meta = m; tokens = toks
        }
    }

    public func transcribe(_ audioURL: URL) async throws -> (text: String, processing: Duration) {
        let allSamples = try Self.load16kMono(audioURL)
        let clock = ContinuousClock()
        let start = clock.now
        let text = try transcribe(samples16k: allSamples)
        return (text, clock.now - start)
    }

    /// Transcribe 16kHz mono samples directly — the app's path: it already holds
    /// the session's audio and shouldn't round-trip through a file.
    public func transcribe(samples16k allSamples: [Float]) throws -> String {
        let (decoder, joint, meta) = lock.withLock { (self.decoder, self.joint, self.meta) }
        guard let decoder, let joint, let meta else {
            throw EvalError.engineUnavailable("prepare() not called")
        }

        // >30s audio exceeds the largest window: split into ~29.4s chunks and
        // join the texts. Crude segmentation (a word can straddle a cut — seen
        // once as a duplicated seam word in a 45s take); Stage 6's VAD
        // segmentation replaces this.
        let maxChunk = 2940 * MelFrontend.hopLength
        var texts: [String] = []
        for chunkStart in stride(from: 0, to: allSamples.count, by: maxChunk) {
            // Decode is uninterruptible Core ML work on a synchronous call, so
            // cancellation is cooperative: the caller's deadline only bites if
            // we look. Chunk granularity is ~15s — too coarse on its own, which
            // is why the per-frame loop checks too.
            try Task.checkCancellation()
            let samples = Array(allSamples[chunkStart..<min(chunkStart + maxChunk, allSamples.count)])
            texts.append(try transcribeChunk(samples, decoder: decoder, joint: joint, meta: meta))
        }
        return texts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Preload encoder packages so the first dictation doesn't pay the model
    /// load. Call off the main thread; each load is O(seconds) from the
    /// compile cache.
    public func warmEncoders(windows: [Int] = ParakeetEngine.windows) {
        for window in windows { _ = try? encoder(for: window) }
    }

    private func transcribeChunk(
        _ samples: [Float], decoder: MLModel, joint: MLModel, meta: Meta
    ) throws -> String {
        // Every prediction returns autoreleased IOSurface-backed outputs; a CLI
        // has no draining pool, so 300-odd utterances exhaust E5 buffer
        // allocation ("Failed to allocate E5 buffer object", 2026-08-07).
        // Drain per chunk.
        try autoreleasepool {
            try transcribeChunkInner(samples, decoder: decoder, joint: joint, meta: meta)
        }
    }

    private func transcribeChunkInner(
        _ samples: [Float], decoder: MLModel, joint: MLModel, meta: Meta
    ) throws -> String {

        // --- mel + pad to enumerated window ---
        let mel = frontend.mel(of: samples)
        let trueFrames = mel[0].count
        guard let window = Self.windows.first(where: { $0 >= trueFrames }) else {
            throw EvalError.audioConversionFailed("\(trueFrames) mel frames exceeds the 30s window — transcribe() should have chunked")
        }

        let melArray = try MLMultiArray(shape: [1, NSNumber(value: meta.mel_dim), NSNumber(value: window)], dataType: .float32)
        let melPtr = melArray.dataPointer.bindMemory(to: Float.self, capacity: meta.mel_dim * window)
        vDSP_vclr(melPtr, 1, vDSP_Length(meta.mel_dim * window))
        for m in 0..<meta.mel_dim {
            mel[m].withUnsafeBufferPointer { src in
                melPtr.advanced(by: m * window).update(from: src.baseAddress!, count: trueFrames)
            }
        }
        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: frontend.validFrames(for: samples.count))

        // --- encoder ---
        try Task.checkCancellation()
        let encClock = ContinuousClock.now
        let encOut = try Self.predictSync(encoder(for: window), ["mel": melArray, "length": lengthArray])
        let encoderMs = Int((ContinuousClock.now - encClock) / .milliseconds(1))
        let encodedArray = encOut.featureValue(for: "encoded")!.multiArrayValue!   // [1, T', D]
        let frames = encOut.featureValue(for: "encoded_len")!.multiArrayValue![0].intValue
        let dModel = encodedArray.shape[2].intValue
        let encoded = Self.floats(encodedArray)

        // --- TDT greedy decode, the loop parity.py verified ---
        // MLMultiArray does NOT zero-initialize; garbage h/c states send the
        // LSTM straight to NaN. (Utterance one of every process worked by the
        // grace of fresh zero pages — the bug that only bites on call two.)
        var h = try MLMultiArray(shape: [NSNumber(value: meta.pred_layers), 1, NSNumber(value: meta.pred_hidden)], dataType: .float32)
        var c = try MLMultiArray(shape: [NSNumber(value: meta.pred_layers), 1, NSNumber(value: meta.pred_hidden)], dataType: .float32)
        memset(h.dataPointer, 0, h.count * MemoryLayout<Float>.size)
        memset(c.dataPointer, 0, c.count * MemoryLayout<Float>.size)
        let tokenIn = try MLMultiArray(shape: [1, 1], dataType: .int32)

        func decoderStep(_ token: Int) throws -> MLMultiArray {
            tokenIn[0] = NSNumber(value: token)
            let out = try Self.predictSync(decoder, ["token": tokenIn, "h_in": h, "c_in": c])
            h = out.featureValue(for: "h_out")!.multiArrayValue!
            c = out.featureValue(for: "c_out")!.multiArrayValue!
            return out.featureValue(for: "dec_out")!.multiArrayValue!
        }

        let encFrame = try MLMultiArray(shape: [1, NSNumber(value: dModel)], dataType: .float32)
        let framePtr = encFrame.dataPointer.bindMemory(to: Float.self, capacity: dModel)

        var decOut = try decoderStep(meta.blank_id)  // blank primes as SOS
        var ids: [Int] = []
        var t = 0
        var emittedAtFrame = 0
        let maxSymbolsPerFrame = 10

        while t < frames {
            // One joint prediction per iteration (~10-40ms), so a cancelled
            // caller is honoured within a frame rather than at chunk end.
            try Task.checkCancellation()
            encoded.withUnsafeBufferPointer { src in
                framePtr.update(from: src.baseAddress! + t * dModel, count: dModel)
            }
            let logitsArray = try Self.predictSync(joint, ["enc_frame": encFrame, "dec_out": decOut])
                .featureValue(for: "logits")!.multiArrayValue!
            let logits = Self.floats(logitsArray)

            var best = 0
            for k in 1...meta.blank_id where logits[k] > logits[best] { best = k }
            var bestDuration = 0
            for d in 1..<meta.durations.count
            where logits[meta.blank_id + 1 + d] > logits[meta.blank_id + 1 + bestDuration] { bestDuration = d }
            var jump = meta.durations[bestDuration]

            if best != meta.blank_id {
                ids.append(best)
                decOut = try decoderStep(best)
                emittedAtFrame += 1
                if jump == 0 && emittedAtFrame >= maxSymbolsPerFrame { jump = 1 }
            } else {
                jump = max(jump, 1)
            }
            if jump > 0 {
                t += jump
                emittedAtFrame = 0
            }
        }

        if ProcessInfo.processInfo.environment["MIMI_PROFILE"] != nil {
            let total = Int((ContinuousClock.now - encClock) / .milliseconds(1))
            print("    profile: enc \(encoderMs)ms, decode \(total - encoderMs)ms (\(frames) frames, \(ids.count) tokens)")
        }
        return ids.map { tokens[$0] }.joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Non-async on purpose: inside an async function, an unqualified
    /// `prediction(from:)` resolves to the async overload, which (observed on
    /// macOS 26) returned wrong results for these fp16 models where the sync
    /// path is correct. This wrapper pins the sync overload.
    private static func predictSync(_ model: MLModel, _ inputs: [String: Any]) throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }

    /// Core ML fp16 models emit Float16 arrays; reading them as Float32 is
    /// garbage. Convert through whatever scalar type the array actually holds.
    public static func floats(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        switch array.dataType {
        case .float32:
            let p = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: p, count: count))
        case .float16:
            let p = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            return UnsafeBufferPointer(start: p, count: count).map(Float.init)
        case .double:
            let p = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            return UnsafeBufferPointer(start: p, count: count).map(Float.init)
        default:
            return (0..<count).map { array[$0].floatValue }
        }
    }

    /// Decode any audio file to 16kHz mono Float32 (excluded from the timed
    /// section by the caller's clock placement).
    public static func load16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let src = file.processingFormat
        guard let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MelFrontend.sampleRate,
                                      channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst) else {
            throw EvalError.audioConversionFailed(url.lastPathComponent)
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw EvalError.audioConversionFailed(url.lastPathComponent)
        }
        try file.read(into: input)

        let outCapacity = AVAudioFrameCount(Double(file.length) * dst.sampleRate / src.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outCapacity) else {
            throw EvalError.audioConversionFailed(url.lastPathComponent)
        }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
