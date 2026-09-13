import Accelerate

/// Cheap silence/transient rejection, not a classifier of speech versus noise.
/// Runs once on the captured 16 kHz samples; no model or idle audio work.
enum SilenceGate {
    static let sampleRate = 16_000
    static let frameSamples = 320 // 20 ms
    static let minimumRMS: Float = 0.002 // about -54 dBFS
    static let minimumActiveSamples = 960 // 60 ms of sustained signal

    struct Assessment {
        var hasSignal: Bool
        var peak: Float
        var maxFrameRMS: Float
        var activeMs: Int
        var longestActiveMs: Int
    }

    static func assess(_ samples: [Float]) -> Assessment {
        var peak: Float = 0
        var maxRMS: Float = 0
        var active = 0, run = 0, longest = 0
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for offset in stride(from: 0, to: buffer.count, by: frameSamples) {
                let count = min(frameSamples, buffer.count - offset)
                let pointer = base.advanced(by: offset)
                var mean: Float = 0, meanSquare: Float = 0, framePeak: Float = 0
                vDSP_meanv(pointer, 1, &mean, vDSP_Length(count))
                vDSP_measqv(pointer, 1, &meanSquare, vDSP_Length(count))
                vDSP_maxmgv(pointer, 1, &framePeak, vDSP_Length(count))
                // Remove DC bias: a nonzero constant is still silence.
                let variance = meanSquare - mean * mean
                guard variance.isFinite, framePeak.isFinite else { run = 0; continue }
                let rms = max(0, variance).squareRoot()
                peak = max(peak, framePeak)
                maxRMS = max(maxRMS, rms)
                if rms >= minimumRMS {
                    active += count
                    run += count
                    longest = max(longest, run)
                } else {
                    run = 0
                }
            }
        }
        return Assessment(
            hasSignal: longest >= minimumActiveSamples,
            peak: peak, maxFrameRMS: maxRMS,
            activeMs: active * 1000 / sampleRate,
            longestActiveMs: longest * 1000 / sampleRate)
    }
}
