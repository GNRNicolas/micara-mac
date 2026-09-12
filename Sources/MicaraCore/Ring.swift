// Ring.swift — the mono FIFO between a producer (WebRTC thread, mic tap) and
// the CoreAudio render thread.
//
// WHY THIS FILE EXISTS (12/09, first live test): the previous ring had no read
// head. Every read took the NEWEST `count` samples before the write head, and
// `filled` was merely decremented. With a producer writing 1024 frames per
// call and a consumer reading 512, each read replayed the second half of the
// last write and the first half never played: the level meter looked right
// (the energy was there) and the other side heard "noises, not a voice". A
// FIFO must be judged on ORDER, not on level — hence the tests next door.
//
// Threading: one producer, one consumer, an `os_unfair_lock` around a memcpy
// of a few hundred floats (never an allocation, never a system call).

import Foundation

public final class MonoRing {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var writeIndex = 0
    private var filled = 0
    private var lock = os_unfair_lock_s()
    /// Peak written since the last `drainPeak` — diagnostics only: the log
    /// must tell "packets arrive but they are silent" from a healthy stream,
    /// which a buffer counter alone cannot.
    private var peakSinceRead: Float = 0

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Samples waiting to be read.
    public var count: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return filled
    }

    /// Appends `count` samples. When the ring is full the OLDEST samples are
    /// dropped: the lag is caught up forwards, never by replaying the past.
    public func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        // A buffer larger than the ring cannot happen (10 ms of WebRTC against
        // 500 ms of ring); should it, only its tail is kept.
        let n = min(count, capacity)
        let src = source + (count - n)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<n { peakSinceRead = max(peakSinceRead, abs(src[i])) }
        let overflow = filled + n - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            filled -= overflow
        }
        let firstChunk = min(n, capacity - writeIndex)
        storage.advanced(by: writeIndex).update(from: src, count: firstChunk)
        if firstChunk < n {
            storage.update(from: src + firstChunk, count: n - firstChunk)
        }
        writeIndex = (writeIndex + n) % capacity
        filled += n
    }

    /// Reads `count` samples in FIFO order into `destination`. If fewer are
    /// waiting, what is there comes first and the rest is zero-filled
    /// (underrun = silence, never noise nor stale sound). Before reading, any
    /// backlog beyond `maxFrames` is dropped from the OLD end: WebRTC's clock
    /// and BlackHole's are not the same one, and without pruning the drift
    /// piles up into permanent latency.
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int, dropOlderThan maxFrames: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(&lock)
        if filled > maxFrames {
            let drop = filled - maxFrames
            readIndex = (readIndex + drop) % capacity
            filled -= drop
        }
        let available = min(filled, count)
        if available > 0 {
            let firstChunk = min(available, capacity - readIndex)
            destination.update(from: storage + readIndex, count: firstChunk)
            if firstChunk < available {
                (destination + firstChunk).update(from: storage, count: available - firstChunk)
            }
            readIndex = (readIndex + available) % capacity
            filled -= available
        }
        if available < count {
            (destination + available).update(repeating: 0, count: count - available)
        }
        os_unfair_lock_unlock(&lock)
    }

    public func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        filled = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Peak written since the last call, then reset to zero.
    public func drainPeak() -> Float {
        os_unfair_lock_lock(&lock)
        defer { peakSinceRead = 0; os_unfair_lock_unlock(&lock) }
        return peakSinceRead
    }
}
