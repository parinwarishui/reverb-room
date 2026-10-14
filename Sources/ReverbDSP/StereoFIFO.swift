//
//  StereoFIFO.swift
//  A sample queue between the tap and the pitch shifter. The pitch shifter asks
//  for input in its own chunk sizes, not one IO cycle at a time, so a cushion of
//  silence is queued up front and the queue absorbs the difference.
//
//  Single-threaded: both ends run on the real-time IO thread.
//

public final class StereoFIFO {
    public let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private var readIndex = 0
    public private(set) var count = 0
    /// Pulls that found too little audio queued (read from other threads).
    public let underflows = AtomicCounter()

    public init(capacity: Int, prefill: Int) {
        self.capacity = capacity
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        count = min(prefill, capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Queues interleaved frames (mono is duplicated, extra channels ignored).
    /// When full, the oldest frames are dropped.
    public func push(interleaved samples: UnsafePointer<Float>, channels: Int, frames: Int) {
        let overflow = count + frames - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            count -= overflow
        }
        var write = (readIndex + count) % capacity
        for f in 0..<frames {
            let s = samples + f * channels
            left[write] = s[0]
            right[write] = channels > 1 ? s[1] : s[0]
            write += 1
            if write == capacity { write = 0 }
        }
        count += frames
    }

    /// Fills `frames` samples per channel, padding with silence if not enough is queued.
    public func pop(_ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>, frames: Int) {
        let available = min(frames, count)
        for f in 0..<available {
            outLeft[f] = left[readIndex]
            outRight[f] = right[readIndex]
            readIndex += 1
            if readIndex == capacity { readIndex = 0 }
        }
        count -= available
        if available < frames {
            (outLeft + available).update(repeating: 0, count: frames - available)
            (outRight + available).update(repeating: 0, count: frames - available)
            underflows.increment()
        }
    }
}
