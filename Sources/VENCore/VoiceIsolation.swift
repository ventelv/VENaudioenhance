import Foundation
import VENDSP

/// Voice isolation: Apple's built-in neural model (AUSoundIsolation, macOS 13+) keeps the voice close to the mic
/// and removes everything else, including other people talking, shouting or playing in the background.
/// Runs on the live mic (on the core's worker thread) and on files, before the rest of the cleanup.
public enum VoiceIsolation {
    public static let isAvailable: Bool = {
        guard let v = ven_isolation_create(Int32(VEN_BLOCK)) else { return false }
        ven_isolation_destroy(v)
        return true
    }()

    /// Samples by which the model delays the signal when fed 480-sample blocks (measured; constant).
    static let delay = 2704

    /// One instance for the live mic.
    final class LiveState {
        let state: OpaquePointer
        init?() {
            guard let v = ven_isolation_create(Int32(VEN_BLOCK)) else { return nil }
            state = v
        }
        deinit { ven_isolation_destroy(state) }

        var stage: ven_live_stage {
            ven_live_stage(process: ven_isolation_process_block, set_param: ven_isolation_set_strength,
                           state: UnsafeMutableRawPointer(state), delay: Int32(VoiceIsolation.delay))
        }
    }

    /// Isolates the voice in each channel. `strength` 0–1 is the share of the isolated signal (1 = all of it).
    static func process(_ audio: PlanarBuffer, strength: Float, progress: (Double) -> Void) throws -> PlanarBuffer {
        let block = Int(VEN_BLOCK)
        let out = PlanarBuffer(channels: audio.channels, frames: audio.frames)
        for c in 0..<audio.channels {
            guard let v = ven_isolation_create(Int32(block)) else {
                throw AudioIOError(message: "Voice isolation needs macOS 13 or later")
            }
            defer { ven_isolation_destroy(v) }
            ven_isolation_set_strength(UnsafeMutableRawPointer(v), strength)
            // Run past the end so the delayed output covers the whole input.
            let padded = (audio.frames + delay) / block * block + block
            var input = [Float](repeating: 0, count: block), result = [Float](repeating: 0, count: padded)
            let src = audio.channel(c)
            var pos = 0
            while pos < padded {
                for i in 0..<block { input[i] = pos + i < audio.frames ? src[pos + i] : 0 }
                result.withUnsafeMutableBufferPointer { r in _ = ven_isolation_run(v, input, r.baseAddress! + pos, Int32(block)) }
                pos += block
                if (pos / block) % 500 == 0 { progress((Double(c) + Double(pos) / Double(padded)) / Double(audio.channels)) }
            }
            if ProcessInfo.processInfo.environment["VEN_DEBUG_DELAY"] != nil {
                let measured = StudioDenoiser.measureDelay(Array(UnsafeBufferPointer(start: src, count: audio.frames)), result, maxLag: 4800)
                FileHandle.standardError.write("voice isolation delay: measured \(measured), assumed \(delay)\n".data(using: .utf8)!)
            }
            result.withUnsafeBufferPointer { r in out.channel(c).update(from: r.baseAddress! + delay, count: audio.frames) }
        }
        return out
    }
}
