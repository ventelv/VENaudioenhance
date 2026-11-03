import Foundation
import VENDSP

/// Numeric checks of the DSP (the Command Line Tools ship without XCTest, so tests live here).
public enum SelfTest {
    public struct Result {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func run() -> [Result] {
        [
            loudnessReference(),
            truePeakDetection(),
            limiterCeiling(),
            chainLatencyAlignment(),
            humRemoval(),
            noiseReduction(),
            levelerSteps(),
            resamplerAccuracy(),
            bypassMatchesInput(),
        ]
    }

    // MARK: Signals

    static func sine(_ freq: Double, amplitude: Double, seconds: Double, rate: Double = 48000, phase: Double = 0) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * freq * Double($0) / rate + phase)) }
    }

    static func noise(_ amplitude: Float, count: Int, seed: UInt64 = 1) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return amplitude * (Float(Int64(bitPattern: state) >> 11) / Float(1 << 52))
        }
    }

    static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let sum = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 10 * log10(sum / Double(max(x.count, 1)) + 1e-20)
    }

    static func goertzelDB(_ x: ArraySlice<Float>, _ freq: Double, rate: Double = 48000) -> Double {
        let coef = 2 * cos(2 * .pi * freq / rate)
        var s1 = 0.0, s2 = 0.0
        for v in x {
            let s = Double(v) + coef * s1 - s2
            s2 = s1
            s1 = s
        }
        let power = s1 * s1 + s2 * s2 - coef * s1 * s2
        return 20 * log10(2 * sqrt(max(power, 0)) / Double(x.count) + 1e-20)
    }

    /// Runs `signal` through a chain in 10 ms blocks and returns the output (same length, latency not removed).
    static func process(_ signal: [Float], settings: VoiceSettings, useNR: Bool = true) -> [Float] {
        let chain = ven_chain_create(1, useNR ? 1 : 0)!
        defer { ven_chain_destroy(chain) }
        var p = settings.params
        ven_chain_set_params(chain, &p)
        var out = signal
        let block = Int(VEN_BLOCK)
        out.append(contentsOf: [Float](repeating: 0, count: (block - signal.count % block) % block))
        out.withUnsafeMutableBufferPointer { buf in
            var i = 0
            while i < buf.count {
                var chans: [UnsafeMutablePointer<Float>?] = [buf.baseAddress! + i]
                ven_chain_process_block(chain, &chans)
                i += block
            }
        }
        return Array(out.prefix(signal.count))
    }

    static func allOff() -> VoiceSettings {
        var s = VoiceSettings()
        s.highPassEnabled = false
        s.humMode = .off
        s.noiseReductionEnabled = false
        s.voiceEQEnabled = false
        s.deEsserEnabled = false
        s.levelerEnabled = false
        s.compressorEnabled = false
        s.pauseGateEnabled = false
        s.limiterEnabled = false
        return s
    }

    static func measure(_ chans: [[Float]], rate: Double = 48000) -> ven_loudness_result {
        Loudness.measure(PlanarBuffer(chans), rate: rate)
    }

    static func mixed(_ a: [Float], _ b: [Float]) -> [Float] {
        var out = a.count >= b.count ? a : b
        let other = a.count >= b.count ? b : a
        for i in other.indices { out[i] += other[i] }
        return out
    }

    // MARK: Checks

    static func loudnessReference() -> Result {
        // EBU Tech 3341 case 1: stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS.
        let s = sine(1000, amplitude: pow(10, -23.0 / 20), seconds: 20)
        let r = measure([s, s])
        let ok = abs(r.integrated_lufs + 23) < 0.1
        return Result(name: "Loudness meter (EBU 3341 -23 LUFS)", passed: ok, detail: String(format: "%.2f LUFS", r.integrated_lufs))
    }

    static func truePeakDetection() -> Result {
        // fs/4 sine at 45° phase: samples peak at -3 dB, the real waveform at 0 dBTP.
        let s = sine(12000, amplitude: 1, seconds: 1, phase: .pi / 4)
        let r = measure([s])
        let ok = abs(r.true_peak_dbtp) < 0.3 && abs(r.sample_peak_dbfs + 3.01) < 0.1
        return Result(name: "True-peak detection", passed: ok,
                      detail: String(format: "sample %.2f dBFS, true %.2f dBTP", r.sample_peak_dbfs, r.true_peak_dbtp))
    }

    static func limiterCeiling() -> Result {
        // Loud noise bursts and an inter-sample-peak tone, 6 dB over full scale.
        var x = mixed(noise(2.0, count: 48000 * 2), sine(11025, amplitude: 1.8, seconds: 1, phase: 0.3))
        let lim = ven_limiter_create(1, -1, 50)!
        defer { ven_limiter_destroy(lim) }
        x.withUnsafeMutableBufferPointer { buf in
            var chans: [UnsafeMutablePointer<Float>?] = [buf.baseAddress]
            ven_limiter_process(lim, &chans, Int32(buf.count))
        }
        let r = measure([x])
        let ok = r.true_peak_dbtp <= -0.9
        return Result(name: "Limiter holds -1 dBTP", passed: ok, detail: String(format: "output %.2f dBTP", r.true_peak_dbtp))
    }

    static func chainLatencyAlignment() -> Result {
        // With RNNoise at full strength, the output must line up with the input at the reported latency.
        let chain = ven_chain_create(1, 1)!
        let latency = Int(ven_chain_latency(chain))
        ven_chain_destroy(chain)

        // A voiced, speech-like test: 140 Hz pulse train through formant resonances, syllable-modulated.
        let n = 48000 * 4
        var x = [Float](repeating: 0, count: n)
        var f1 = (0.0, 0.0), f2 = (0.0, 0.0)
        for i in 0..<n {
            let t = Double(i) / 48000
            let pulse = i % Int(48000 / 140) == 0 ? 1.0 : 0.0
            let env = 0.5 + 0.5 * sin(2 * .pi * 3 * t)
            func reson(_ input: Double, _ state: inout (Double, Double), _ f: Double, _ bw: Double) -> Double {
                let r = exp(-.pi * bw / 48000), c = 2 * r * cos(2 * .pi * f / 48000)
                let y = input + c * state.0 - r * r * state.1
                state.1 = state.0
                state.0 = y
                return y
            }
            let v = reson(reson(pulse, &f1, 700, 120), &f2, 1200, 150)
            x[i] = Float(0.02 * env * v)
        }
        var s = allOff()
        s.noiseReductionEnabled = true
        s.noiseReductionStrength = 1
        let y = process(x, settings: s)
        var best = 0, bestCorr = -Double.infinity
        for lag in stride(from: latency - 1500, through: latency + 1500, by: 1) where lag >= 0 {
            var corr = 0.0
            for i in stride(from: 48000, to: n - lag, by: 3) { corr += Double(x[i]) * Double(y[i + lag]) }
            if corr > bestCorr { bestCorr = corr; best = lag }
        }
        let ok = abs(best - latency) <= 2
        return Result(name: "RNNoise output aligned with latency", passed: ok, detail: "peak at \(best), reported \(latency)")
    }

    static func humRemoval() -> Result {
        // Speech-band tone plus 60 Hz hum with harmonics; auto-detect must find it and notch it out.
        let secs = 6.0
        var x = sine(1000, amplitude: 0.1, seconds: secs)
        for k in 1...5 { x = mixed(x, sine(60 * Double(k), amplitude: 0.05 / Double(k), seconds: secs)) }
        x = mixed(x, noise(0.001, count: x.count))
        var s = allOff()
        s.humMode = .auto
        let y = process(x, settings: s, useNR: false)
        let tail = y.suffix(48000)
        let src = x.suffix(48000)
        let humCut = goertzelDB(src, 120) - goertzelDB(tail, 120)
        let toneChange = abs(goertzelDB(src, 1000) - goertzelDB(tail, 1000))
        let ok = humCut > 30 && toneChange < 0.5
        return Result(name: "Hum auto-detect and removal", passed: ok,
                      detail: String(format: "120 Hz down %.1f dB, 1 kHz changed %.2f dB", humCut, toneChange))
    }

    static func noiseReduction() -> Result {
        let x = noise(0.03, count: 48000 * 4)
        var s = allOff()
        s.noiseReductionEnabled = true
        s.noiseReductionStrength = 1
        let y = process(x, settings: s)
        let reduction = rmsDB(x.suffix(48000)) - rmsDB(y.suffix(48000))
        let ok = reduction > 15
        return Result(name: "RNNoise removes steady noise", passed: ok, detail: String(format: "%.1f dB quieter", reduction))
    }

    static func levelerSteps() -> Result {
        // Without RNNoise the VAD reads "speech", so this exercises the AGC alone.
        var s = allOff()
        s.levelerEnabled = true
        s.levelerTargetDB = -20
        let quiet = sine(500, amplitude: pow(10, -32.0 / 20) * sqrt(2), seconds: 8)
        let loud = sine(500, amplitude: pow(10, -10.0 / 20) * sqrt(2), seconds: 8)
        let y = process(quiet + loud, settings: s, useNR: false)
        let a = rmsDB(y[(48000 * 7)..<(48000 * 8)])
        let b = rmsDB(y[(48000 * 15)..<(48000 * 16)])
        let ok = abs(a + 20) < 2 && abs(b + 20) < 2
        return Result(name: "Leveler evens out ±12 dB steps", passed: ok, detail: String(format: "%.1f / %.1f dBFS (target -20)", a, b))
    }

    static func resamplerAccuracy() -> Result {
        let input = sine(1000, amplitude: 0.5, seconds: 2, rate: 44100)
        let rs = ven_resampler_create(44100, 48000)!
        defer { ven_resampler_destroy(rs) }
        var out: [Float] = []
        var pos = 0
        var block = [Float](repeating: 0, count: 480)
        while true {
            let need = Int(ven_resampler_input_needed(rs, 480))
            if pos + need > input.count { break }
            input[pos..<(pos + need)].withUnsafeBufferPointer { _ = ven_resampler_push(rs, $0.baseAddress, Int32(need)) }
            pos += need
            _ = ven_resampler_produce(rs, &block, 480)
            out.append(contentsOf: block)
        }
        // Least-squares fit of a 1 kHz sine (any phase); what's left is distortion and noise.
        let seg = Array(out[48000..<72000])
        var ss = 0.0, sc = 0.0, cc = 0.0, xs = 0.0, xc = 0.0
        for (i, v) in seg.enumerated() {
            let w = 2 * Double.pi * 1000 * Double(i) / 48000
            let (sn, cs) = (sin(w), cos(w))
            ss += sn * sn; sc += sn * cs; cc += cs * cs; xs += Double(v) * sn; xc += Double(v) * cs
        }
        let det = ss * cc - sc * sc
        let a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det
        var resid = 0.0
        for (i, v) in seg.enumerated() {
            let w = 2 * Double.pi * 1000 * Double(i) / 48000
            let e = Double(v) - (a * sin(w) + b * cos(w))
            resid += e * e
        }
        let amplitude = sqrt(a * a + b * b)
        let snr = 10 * log10((amplitude * amplitude / 2 * Double(seg.count)) / max(resid, 1e-30))
        let ok = snr > 80 && abs(amplitude - 0.5) < 0.005
        return Result(name: "Resampler 44.1→48 kHz", passed: ok, detail: String(format: "amplitude %.4f, SNR %.0f dB", amplitude, snr))
    }

    static func bypassMatchesInput() -> Result {
        var s = VoiceSettings()
        s.bypass = true
        let x = noise(0.1, count: 48000)
        let chain = ven_chain_create(1, 1)!
        let latency = Int(ven_chain_latency(chain))
        ven_chain_destroy(chain)
        let y = process(x, settings: s)
        var maxErr: Float = 0
        for i in 24000..<(x.count - latency) { maxErr = max(maxErr, abs(y[i + latency] - x[i])) }
        return Result(name: "Bypass is the input, latency-matched", passed: maxErr < 1e-5, detail: String(format: "max error %.2g", maxErr))
    }
}
