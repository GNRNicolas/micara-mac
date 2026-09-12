// A FIFO is judged on ORDER. The bug these tests pin down (12/09): a ring that
// reads "the newest samples" instead of following a read head keeps the level
// right and the content wrong — the far end hears noise, not a voice.

import Foundation
import Testing
@testable import MicaraCore

@Suite("MonoRing")
struct RingTests {
    private func write(_ ring: MonoRing, _ values: [Float]) {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    }

    private func read(_ ring: MonoRing, _ count: Int, maxFrames: Int = .max) -> [Float] {
        var out = [Float](repeating: -99, count: count)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count, dropOlderThan: maxFrames) }
        return out
    }

    @Test func readsInWriteOrderAcrossUnevenBlockSizes() {
        // Producer: 1024 per call (the mic tap). Consumer: 512 per call (the
        // render block). Every sample must come out once, in order.
        let ring = MonoRing(capacity: 4096)
        var expected: [Float] = []
        var got: [Float] = []
        var next: Float = 0
        for _ in 0..<6 {
            let block = (0..<1024).map { _ in next += 1; return next }
            expected += block
            write(ring, block)
            got += read(ring, 512)
            got += read(ring, 512)
        }
        #expect(got == expected)
    }

    @Test func wrapsAroundTheEndOfStorage() {
        let ring = MonoRing(capacity: 10)
        write(ring, [1, 2, 3, 4, 5, 6, 7])
        #expect(read(ring, 5) == [1, 2, 3, 4, 5])
        write(ring, [8, 9, 10, 11, 12, 13])   // crosses index 10 → 0
        #expect(read(ring, 8) == [6, 7, 8, 9, 10, 11, 12, 13])
    }

    @Test func underrunPadsWithSilenceAfterWhatIsThere() {
        let ring = MonoRing(capacity: 16)
        write(ring, [1, 2, 3])
        #expect(read(ring, 6) == [1, 2, 3, 0, 0, 0])
        #expect(ring.count == 0)
    }

    @Test func overflowDropsTheOldest() {
        let ring = MonoRing(capacity: 8)
        write(ring, [1, 2, 3, 4, 5, 6])
        write(ring, [7, 8, 9, 10])   // 10 > 8: 1 and 2 go
        #expect(ring.count == 8)
        #expect(read(ring, 8) == [3, 4, 5, 6, 7, 8, 9, 10])
    }

    @Test func pruningDropsTheOldestBeyondTheLatencyCeiling() {
        let ring = MonoRing(capacity: 64)
        write(ring, (1...20).map(Float.init))
        // Only 8 frames of backlog tolerated: 1…12 are thrown away.
        #expect(read(ring, 4, maxFrames: 8) == [13, 14, 15, 16])
        #expect(read(ring, 4, maxFrames: 8) == [17, 18, 19, 20])
    }

    @Test func writeLargerThanCapacityKeepsTheTail() {
        let ring = MonoRing(capacity: 4)
        write(ring, [1, 2, 3, 4, 5, 6])
        #expect(read(ring, 4) == [3, 4, 5, 6])
    }

    @Test func peakIsTrackedAndDrained() {
        let ring = MonoRing(capacity: 8)
        write(ring, [0.1, -0.7, 0.3])
        #expect(ring.drainPeak() == 0.7)
        #expect(ring.drainPeak() == 0)
    }
}
