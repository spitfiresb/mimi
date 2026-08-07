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
    private nonisolated(unsafe) var encoder: MLModel?
    private nonisolated(unsafe) var decoder: MLModel?
    private nonisolated(unsafe) var joint: MLModel?
    private nonisolated(unsafe) var meta: Meta?
    private nonisolated(unsafe) var tokens: [String] = []
    private let suffix: String

    /// The encoder ships with enumerated shapes (a flexible axis crashes the
    /// BNNS compiler); pad mels up to the smallest allowed window.
    static let windows = [301, 1501, 3001]

    public init(modelsDir: URL, int8: Bool = true) {
        self.modelsDir = modelsDir
        self.suffix = int8 ? "-int8" : ""
        self.name = int8 ? "Parakeet-int8" : "Parakeet-fp16"
    }

    public func prepare() async throws {
        let config = MLModelConfiguration()
        // CPU_AND_NE segfaults in BNNS graph compile (see Stage 4a); .all lets
        // unsupported segments fall to GPU. Stage 5 audits actual ANE residency.
        config.computeUnits = .all

        func load(_ base: String) throws -> MLModel {
            let package = modelsDir.appendingPathComponent("\(base)\(suffix).mlpackage")
            guard FileManager.default.fileExists(atPath: package.path) else {
                throw EvalError.engineUnavailable("missing \(package.lastPathComponent) — run tools/convert/export.py")
            }
            let compiled = try MLModel.compileModel(at: package)
            return try MLModel(contentsOf: compiled, configuration: config)
        }

        let enc = try load("ParakeetEncoder")
        let dec = try load("ParakeetDecoder")
        let jnt = try load("ParakeetJoint")
        let m = try JSONDecoder().decode(
            Meta.self,
            from: Data(contentsOf: modelsDir.appendingPathComponent("parakeet-meta.json"))
        )
        let toks = try String(contentsOf: modelsDir.appendingPathComponent("tokens.txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        lock.withLock {
            encoder = enc; decoder = dec; joint = jnt; meta = m; tokens = toks
        }
    }

    public func transcribe(_ audioURL: URL) async throws -> (text: String, processing: Duration) {
        let (encoder, decoder, joint, meta) = lock.withLock { (self.encoder, self.decoder, self.joint, self.meta) }
        guard let encoder, let decoder, let joint, let meta else {
            throw EvalError.engineUnavailable("prepare() not called")
        }

        let allSamples = try Self.load16kMono(audioURL)

        let clock = ContinuousClock()
        let start = clock.now

        // >30s audio exceeds the largest enumerated window: split into ~29.4s
        // chunks and join the texts. Crude segmentation (a word can straddle a
        // cut) but it keeps every utterance scoreable; the app never dictates
        // 30s unbroken anyway.
        let maxChunk = 2940 * MelFrontend.hopLength
        var texts: [String] = []
        for chunkStart in stride(from: 0, to: allSamples.count, by: maxChunk) {
            let samples = Array(allSamples[chunkStart..<min(chunkStart + maxChunk, allSamples.count)])
            texts.append(try transcribeChunk(samples, encoder: encoder, decoder: decoder, joint: joint, meta: meta))
        }
        return (texts.joined(separator: " ").trimmingCharacters(in: .whitespaces), clock.now - start)
    }

    private func transcribeChunk(
        _ samples: [Float], encoder: MLModel, decoder: MLModel, joint: MLModel, meta: Meta
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
        let encOut = try Self.predictSync(encoder, ["mel": melArray, "length": lengthArray])
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
