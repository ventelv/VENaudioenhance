import Foundation
import VENDSP

/// Multichannel audio as separately allocated channel arrays, ready to hand to the C DSP.
public final class PlanarBuffer {
    public let channels: Int
    public private(set) var frames: Int
    private var storage: [UnsafeMutablePointer<Float>]

    public init(channels: Int, frames: Int) {
        self.channels = channels
        self.frames = frames
        storage = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
            p.initialize(repeating: 0, count: max(frames, 1))
            return p
        }
    }

    public convenience init(_ arrays: [[Float]]) {
        self.init(channels: arrays.count, frames: arrays.first?.count ?? 0)
        for (c, a) in arrays.enumerated() { a.withUnsafeBufferPointer { storage[c].update(from: $0.baseAddress!, count: a.count) } }
    }

    deinit { storage.forEach { $0.deallocate() } }

    public func channel(_ c: Int) -> UnsafeMutablePointer<Float> { storage[c] }

    public func array(_ c: Int) -> [Float] { Array(UnsafeBufferPointer(start: storage[c], count: frames)) }

    /// Pointers to every channel starting at `offset`, in the `float *const *` shape the C API takes.
    public func withPointers<R>(offset: Int = 0, _ body: (UnsafeMutablePointer<UnsafeMutablePointer<Float>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<Float>?] = storage.map { $0 + offset }
        return ptrs.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    public func withConstPointers<R>(offset: Int = 0, _ body: (UnsafePointer<UnsafePointer<Float>?>) -> R) -> R {
        let ptrs: [UnsafePointer<Float>?] = storage.map { UnsafePointer($0 + offset) }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    /// A copy with frames [start, start+count), zero-padded past the end.
    public func slice(_ start: Int, _ count: Int) -> PlanarBuffer {
        let out = PlanarBuffer(channels: channels, frames: count)
        let n = max(0, min(count, frames - start))
        for c in 0..<channels where n > 0 { out.storage[c].update(from: storage[c] + start, count: n) }
        return out
    }
}

public enum Loudness {
    public static func measure(_ buffer: PlanarBuffer, rate: Double = 48000) -> ven_loudness_result {
        let meter = ven_loudness_create(rate, Int32(buffer.channels))!
        defer { ven_loudness_destroy(meter) }
        buffer.withConstPointers { ven_loudness_add(meter, $0, Int64(buffer.frames)) }
        var r = ven_loudness_result()
        ven_loudness_result_get(meter, &r)
        return r
    }
}
