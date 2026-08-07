import Accelerate
import Foundation

/// NeMo's AudioToMelSpectrogramPreprocessor, reimplemented on vDSP.
///
/// Every constant here mirrors the checkpoint's preprocessor config (dumped in
/// tools/convert): 16kHz, hann 400/160, n_fft 512, 128 slaney-normalized mel
/// bins, log with a 2^-24 guard, then per-feature mean/variance normalization
/// over the valid frames. Dither is train-only and preemphasis is 0.97.
/// MelFrontendTests pins this against mels dumped from NeMo itself — the
/// tolerance there is the contract, not this comment.
public struct MelFrontend: @unchecked Sendable {
    public static let sampleRate = 16_000.0
    static let nFFT = 512
    static let winLength = 400
    static let hop = 160
    public static var hopLength: Int { hop }
    static let melBins = 128
    static let preemph: Float = 0.97
    static let logGuard = Float(exp2(-24.0))

    private let window: [Float]          // hann(400) centered in 512
    private let filterbank: [Float]      // [melBins x (nFFT/2+1)], row-major
    private let fft: FFTSetup

    public init() {
        var w = [Float](repeating: 0, count: Self.nFFT)
        let pad = (Self.nFFT - Self.winLength) / 2
        for n in 0..<Self.winLength {
            // SYMMETRIC hann — NeMo passes periodic=False, unlike torch's default
            w[pad + n] = 0.5 * (1 - cos(2 * .pi * Float(n) / Float(Self.winLength - 1)))
        }
        window = w
        filterbank = Self.slaneyFilterbank()
        fft = vDSP_create_fftsetup(vDSP_Length(log2(Double(Self.nFFT))), FFTRadix(kFFTRadix2))!
    }

    /// 16kHz mono samples -> [melBins][frames] mel, normalized. Frame count is
    /// floor(samples/hop)+1, matching torch.stft(center=true).
    public func mel(of samples: [Float]) -> [[Float]] {
        // Preemphasis: x[t] - 0.97 x[t-1], x[0] untouched.
        var x = samples
        for i in stride(from: x.count - 1, through: 1, by: -1) {
            x[i] -= Self.preemph * x[i - 1]
        }

        // Zero-pad nFFT/2 on both sides — NeMo's stft uses pad_mode="constant",
        // not torch's reflect default.
        let half = Self.nFFT / 2
        var padded = [Float](repeating: 0, count: x.count + Self.nFFT)
        padded.replaceSubrange(half..<(half + x.count), with: x)

        // NeMo emits floor(n/hop)+1 stft frames but declares only floor(n/hop)
        // valid: stats are computed over the valid frames and the tail frame is
        // masked to zero after normalization. validFrames is what the encoder
        // gets as its length input.
        let frames = samples.count / Self.hop + 1
        let valid = samples.count / Self.hop
        let bins = Self.nFFT / 2 + 1

        var windowed = [Float](repeating: 0, count: Self.nFFT)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: bins)
        var melFrame = [Float](repeating: 0, count: Self.melBins)
        var mel = [[Float]](repeating: [Float](repeating: 0, count: frames), count: Self.melBins)

        for t in 0..<frames {
            let start = t * Self.hop
            padded.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(Self.nFFT))
            }
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBytes {
                        vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                    vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2(Double(Self.nFFT))), FFTDirection(FFT_FORWARD))
                    // zrip output is 2x the DFT; power needs /4. DC and Nyquist
                    // arrive packed in realp[0]/imagp[0].
                    let dc = rp.baseAddress![0] / 2
                    let nyquist = ip.baseAddress![0] / 2
                    power[0] = dc * dc
                    power[bins - 1] = nyquist * nyquist
                    for k in 1..<half {
                        let re = rp.baseAddress![k] / 2
                        let im = ip.baseAddress![k] / 2
                        power[k] = re * re + im * im
                    }
                }
            }
            filterbank.withUnsafeBufferPointer { fb in
                vDSP_mmul(fb.baseAddress!, 1, power, 1, &melFrame, 1,
                          vDSP_Length(Self.melBins), 1, vDSP_Length(bins))
            }
            for m in 0..<Self.melBins {
                mel[m][t] = log(melFrame[m] + Self.logGuard)
            }
        }

        // Per-feature normalization over the VALID frames only; frames beyond
        // valid are masked to pad_value 0 afterward, mirroring NeMo exactly.
        for m in 0..<Self.melBins {
            var mean: Float = 0
            vDSP_meanv(mel[m], 1, &mean, vDSP_Length(valid))
            var variance: Float = 0
            for t in 0..<valid {
                let d = mel[m][t] - mean
                variance += d * d
            }
            let std = sqrt(variance / Float(max(valid - 1, 1)))
            let denom = std + 1e-5
            for t in 0..<valid {
                mel[m][t] = (mel[m][t] - mean) / denom
            }
            for t in valid..<frames {
                mel[m][t] = 0
            }
        }
        return mel
    }

    /// The frame count the encoder should be told about (NeMo's out_len).
    public func validFrames(for sampleCount: Int) -> Int { sampleCount / Self.hop }

    /// librosa.filters.mel(16000, 512, n_mels=128) — slaney scale, slaney norm,
    /// fmin 0, fmax 8000. The scale is linear below 1kHz, logarithmic above.
    private static func slaneyFilterbank() -> [Float] {
        let bins = nFFT / 2 + 1
        func hzToMel(_ hz: Double) -> Double {
            if hz < 1000 { return hz / (200.0 / 3.0) }
            return 15.0 + Foundation.log(hz / 1000.0) / Foundation.log(6.4) * 27.0
        }
        func melToHz(_ mel: Double) -> Double {
            if mel < 15 { return mel * (200.0 / 3.0) }
            return 1000.0 * Foundation.exp(Foundation.log(6.4) / 27.0 * (mel - 15.0))
        }
        let maxMel = hzToMel(sampleRate / 2)
        let melPoints = (0...melBins + 1).map { melToHz(maxMel * Double($0) / Double(melBins + 1)) }
        let fftFreqs = (0..<bins).map { Double($0) * sampleRate / Double(nFFT) }

        var fb = [Float](repeating: 0, count: melBins * bins)
        for m in 0..<melBins {
            let lower = melPoints[m], center = melPoints[m + 1], upper = melPoints[m + 2]
            let enorm = 2.0 / (upper - lower)  // slaney area normalization
            for k in 0..<bins {
                let f = fftFreqs[k]
                let rising = (f - lower) / (center - lower)
                let falling = (upper - f) / (upper - center)
                let weight = max(0, min(rising, falling))
                fb[m * bins + k] = Float(weight * enorm)
            }
        }
        return fb
    }
}
