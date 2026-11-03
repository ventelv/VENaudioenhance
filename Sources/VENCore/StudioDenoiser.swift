import Accelerate
import Foundation

/// DeepFilterNet 3 noise reduction, loaded at run time from libdf (built by scripts/build-deepfilter.sh).
/// It handles changing noise (keyboards, traffic, room tone) better than RNNoise. Offline only: the library
/// allocates while it runs, so it isn't safe in the live audio thread.
public enum StudioDenoiser {
    private typealias Create = @convention(c) (UnsafePointer<CChar>, Float, UnsafePointer<CChar>?) -> OpaquePointer?
    private typealias FrameLength = @convention(c) (OpaquePointer) -> Int
    private typealias ProcessFrame = @convention(c) (OpaquePointer, UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Float
    private typealias Free = @convention(c) (OpaquePointer) -> Void

    private struct Library {
        let create: Create
        let frameLength: FrameLength
        let process: ProcessFrame
        let free: Free
        let model: String
    }

    /// Where libdf.dylib and DeepFilterNet3_onnx.tar.gz are looked for: inside the app, then the build folder.
    static var searchFolders: [URL] {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources.appendingPathComponent("DeepFilterNet")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        folders.append(exe.deletingLastPathComponent().appendingPathComponent("Resources/DeepFilterNet"))   // ven-cli inside the app
        // Running from the project (e.g. .build/arm64-apple-macosx/release/ven-cli): build/deps/out above it.
        var dir = exe
        for _ in 0..<5 {
            dir = dir.deletingLastPathComponent()
            folders.append(dir.appendingPathComponent("build/deps/out"))
        }
        folders.append(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VEN Audio Enhance/DeepFilterNet"))
        return folders
    }

    private static let library: Library? = {
        for folder in searchFolders {
            let lib = folder.appendingPathComponent("libdf.dylib"), model = folder.appendingPathComponent("DeepFilterNet3_onnx.tar.gz")
            guard FileManager.default.fileExists(atPath: lib.path), FileManager.default.fileExists(atPath: model.path),
                  let handle = dlopen(lib.path, RTLD_NOW | RTLD_LOCAL)
            else { continue }
            func symbol<T>(_ name: String, as: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: T.self) } }
            guard let create = symbol("df_create", as: Create.self), let frameLength = symbol("df_get_frame_length", as: FrameLength.self),
                  let process = symbol("df_process_frame", as: ProcessFrame.self), let free = symbol("df_free", as: Free.self)
            else { dlclose(handle); continue }
            return Library(create: create, frameLength: frameLength, process: process, free: free, model: model.path)
        }
        return nil
    }()

    public static var isAvailable: Bool { library != nil }

    /// Denoises each channel. `strength` 0–1 maps to DeepFilterNet's attenuation limit (1 = no limit).
    static func process(_ audio: PlanarBuffer, strength: Float, progress: (Double) -> Void) throws -> PlanarBuffer {
        guard let lib = library else {
            throw AudioIOError(message: "The Studio noise engine isn't installed. Run scripts/build-deepfilter.sh, then rebuild the app.")
        }
        let limit: Float = strength >= 0.99 ? 100 : 6 + 40 * max(0, strength)
        let out = PlanarBuffer(channels: audio.channels, frames: audio.frames)
        for c in 0..<audio.channels {
            guard let state = lib.model.withCString({ lib.create($0, limit, nil) }) else {
                throw AudioIOError(message: "DeepFilterNet couldn't load its model")
            }
            defer { lib.free(state) }
            let hop = lib.frameLength(state)
            // Run past the end so the delayed output covers the whole input.
            let padded = audio.frames + 4 * hop + 4800
            var input = [Float](repeating: 0, count: hop), result = [Float](repeating: 0, count: (padded / hop + 1) * hop)
            let src = audio.channel(c)
            var pos = 0
            while pos < padded {
                for i in 0..<hop { input[i] = pos + i < audio.frames ? src[pos + i] : 0 }
                result.withUnsafeMutableBufferPointer { r in _ = lib.process(state, &input, r.baseAddress! + pos) }
                pos += hop
                if (pos / hop) % 500 == 0 { progress((Double(c) + Double(pos) / Double(padded)) / Double(audio.channels)) }
            }
            // The model delays the signal by its STFT and look-ahead; find that delay from the audio itself.
            let delay = measureDelay(Array(UnsafeBufferPointer(start: src, count: audio.frames)), result, maxLag: 4800)
            result.withUnsafeBufferPointer { r in out.channel(c).update(from: r.baseAddress! + delay, count: audio.frames) }
        }
        return out
    }

    /// The lag (0…maxLag samples) at which `output` best matches `input`, measured over the loudest 2 s.
    static func measureDelay(_ input: [Float], _ output: [Float], maxLag: Int) -> Int {
        let window = min(96000, input.count)
        guard window > 0, output.count >= window + maxLag else { return 0 }
        // Pick the loudest stretch (speech survives denoising, noise doesn't).
        var best = 0, bestEnergy: Float = -1
        for start in stride(from: 0, to: max(1, input.count - window), by: window / 2) {
            var e: Float = 0
            vDSP_svesq(Array(input[start..<(start + window)]), 1, &e, vDSP_Length(window))
            if e > bestEnergy { bestEnergy = e; best = start }
        }
        var bestLag = 0, bestScore = -Float.infinity
        input.withUnsafeBufferPointer { x in
            output.withUnsafeBufferPointer { y in
                for lag in 0...maxLag where best + lag + window <= y.count {
                    var dot: Float = 0
                    vDSP_dotpr(x.baseAddress! + best, 1, y.baseAddress! + best + lag, 1, &dot, vDSP_Length(window))
                    if dot > bestScore { bestScore = dot; bestLag = lag }
                }
            }
        }
        return bestLag
    }
}
