import Foundation

/// Simple bounded mono float32 ring buffer mirroring the JS `MonoRingBuffer`
/// and the Kotlin `FloatRingBuffer` used by ``AudioPipelineCore``. Not
/// thread-safe — callers must externally serialise push/pull.
internal final class FloatRingBuffer {
    private var data: [Float]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private(set) var framesAvailable: Int = 0

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "FloatRingBuffer capacity must be > 0")
        self.capacity = capacity
        self.data = [Float](repeating: 0, count: capacity)
    }

    func push(_ input: [Float]) {
        push(input, count: input.count)
    }

    func push(_ input: [Float], count: Int) {
        if count == 0 { return }
        let cap = capacity
        let tail = cap - writeIndex

        input.withUnsafeBufferPointer { src in
            data.withUnsafeMutableBufferPointer { dst in
                let srcBase = src.baseAddress!
                let dstBase = dst.baseAddress!
                if count <= tail {
                    dstBase.advanced(by: writeIndex).update(from: srcBase, count: count)
                } else {
                    dstBase.advanced(by: writeIndex).update(from: srcBase, count: tail)
                    dstBase.update(from: srcBase.advanced(by: tail), count: count - tail)
                }
            }
        }

        writeIndex = (writeIndex + count) % cap
        framesAvailable = min(framesAvailable + count, cap)
    }

    /// Pull exactly `target.count` samples into `target`. Returns `true` when
    /// the read succeeded; returns `false` and zero-fills `target` when fewer
    /// samples are available.
    @discardableResult
    func pull(into target: inout [Float]) -> Bool {
        let len = target.count
        if framesAvailable < len {
            for i in 0..<len { target[i] = 0 }
            return false
        }

        let cap = capacity
        let tail = cap - readIndex

        data.withUnsafeBufferPointer { src in
            target.withUnsafeMutableBufferPointer { dst in
                let srcBase = src.baseAddress!
                let dstBase = dst.baseAddress!
                if len <= tail {
                    dstBase.update(from: srcBase.advanced(by: readIndex), count: len)
                } else {
                    dstBase.update(from: srcBase.advanced(by: readIndex), count: tail)
                    dstBase.advanced(by: tail).update(from: srcBase, count: len - tail)
                }
            }
        }

        readIndex = (readIndex + len) % cap
        framesAvailable -= len
        return true
    }

    func clear() {
        readIndex = 0
        writeIndex = 0
        framesAvailable = 0
        for i in 0..<capacity { data[i] = 0 }
    }
}
