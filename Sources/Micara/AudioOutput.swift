// AudioOutput.swift — the output graph's audio-thread half, split out of
// Audio.swift: the mix state published to the CoreAudio render block, that
// block itself, and the output limiter.
//
// THIS IS THE ONLY REAL-TIME CODE IN THE PROJECT. Everything reached from
// `render` runs on the CoreAudio thread, which may NOT allocate, may NOT take
// a lock it could wait on, and may NOT call anything that does either. The
// buffers are pre-allocated in `init`, the state lock is only ever `trylock`ed
// from the audio thread, and the channel list arrives as a snapshot published
// from the control queue. Keeping it in a file of its own is what makes that
// constraint checkable at a glance.

import AVFoundation
import Foundation
import MicaraCore

// MARK: - Constants

/// Output limiter: same constants as the JS `DynamicsCompressor` (`mixComp`),
/// tuned in real meetings. Without it, the +10 dB input gain plus close speech
/// clip at the final conversion ("distorted voice", 19/08).
private let limiterThresholdDb: Float = -6
private let limiterKneeDb: Float = 6
private let limiterRatio: Float = 20
private let limiterAttackSec: Float = 0.002
private let limiterReleaseSec: Float = 0.15

/// Ceiling on the lag tolerated in a ring buffer before the oldest samples are
/// dropped. WHY: WebRTC's clock and BlackHole's are not the same one; without
/// pruning, the drift piles up into permanent latency.
private let maxRingLatencySec: Double = 0.20

// MARK: - Audio-thread state

/// Everything the render block touches. A separate object (rather than
/// `AudioEngine`) so the block can capture it strongly without creating a cycle
/// with the engine.
final class Mixdown {
    var config: MixerConfig
    private var stateLock = os_unfair_lock_s()
    private var pendingChannels: [Channel]?
    /// Copy owned by the audio thread alone: avoids taking the lock when
    /// nothing has changed (the case for 99.99 % of blocks).
    private var renderChannels: [Channel] = []

    private var _mode: MixMode = .dominance
    private var _muted = false
    private var outSumSquares: Double = 0
    private var outSampleCount: Int = 0
    /// Number of rendered blocks — diagnostics: zero = the output graph is not
    /// running at all (device taken by another process, format refused…).
    private(set) var renderCount: Int = 0

    // Pre-allocated buffers: no allocation in the render block.
    private let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private let mix: UnsafeMutablePointer<Float>

    // Limiter state (audio thread only).
    private var envelope: Float = 0
    private let attackCoef: Float
    private let releaseCoef: Float

    init(config: MixerConfig) {
        self.config = config
        scratch = .allocate(capacity: maxFrames)
        mix = .allocate(capacity: maxFrames)
        scratch.initialize(repeating: 0, count: maxFrames)
        mix.initialize(repeating: 0, count: maxFrames)
        let dt = Float(1.0 / mixSampleRate)
        attackCoef = 1 - expf(-dt / limiterAttackSec)
        releaseCoef = 1 - expf(-dt / limiterReleaseSec)
    }

    deinit {
        scratch.deinitialize(count: maxFrames)
        scratch.deallocate()
        mix.deinitialize(count: maxFrames)
        mix.deallocate()
    }

    var mode: MixMode {
        get { withLock { _mode } }
        set { withLock { _mode = newValue } }
    }

    var phonesMuted: Bool {
        get { withLock { _muted } }
        set { withLock { _muted = newValue } }
    }

    func publish(channels: [Channel]) {
        withLock { pendingChannels = channels }
    }

    /// Snapshot for the tick (off the audio thread).
    func channelsSnapshot() -> [Channel] {
        withLock { pendingChannels ?? renderChannels }
    }

    /// Level of the mix over the elapsed window, in dBFS. `nil` if the engine
    /// has not rendered a single block since the last call (engine stopped).
    func drainOutputDb() -> Float? {
        var s: Double = 0
        var n = 0
        withLock {
            s = outSumSquares
            n = outSampleCount
            outSumSquares = 0
            outSampleCount = 0
        }
        return meanSquareDb(sumSquares: s, count: n)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return body()
    }

    // MARK: render block (CoreAudio thread — no allocation, no long lock)

    func render(frameCount: Int, output: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        let frames = min(frameCount, maxFrames)
        renderCount += 1

        // Pick up the new channel list WITHOUT blocking: if the tick or the
        // main queue holds the lock, we keep the previous list for one more
        // block (5-10 ms) rather than wait on the audio thread.
        if os_unfair_lock_trylock(&stateLock) {
            if let pending = pendingChannels {
                renderChannels = pending
                pendingChannels = nil
            }
            os_unfair_lock_unlock(&stateLock)
        }
        let muted = _muted  // unlocked read of a Bool: at worst we apply the
        // previous value for one block.

        mix.update(repeating: 0, count: frames)
        let inputGain = gainFromDb(config.inputGainDb)
        let maxLatencyFrames = Int(maxRingLatencySec * mixSampleRate)
        let dt = Float(Double(frames) / mixSampleRate)

        for channel in renderChannels {
            channel.ring.read(into: scratch, count: frames, dropOlderThan: maxLatencyFrames)

            // Input gain BEFORE the measurement: that is the JS order (source →
            // inputGain → analyser), and it is what makes the -45 dB gate open
            // for a phone lying two metres away.
            var sumSq: Double = 0
            for i in 0..<frames {
                let s = scratch[i] * inputGain
                scratch[i] = s
                sumSq += Double(s) * Double(s)
            }
            channel.accumulate(sumSquares: sumSq, count: frames)

            // The Mac's mic is NEVER silenced by "Mute": the admin must stay
            // audible in Teams (rule 6 of the spec).
            let target = (muted && !channel.isLocal) ? 0 : channel.targetGain
            let from = channel.smoother.value
            let to = channel.smoother.step(target: target, dtSec: dt)
            // Linear ramp across the block: applying the smoothed gain as a
            // staircase (one value per block) is audible as a click on every
            // switch.
            let slope = frames > 1 ? (to - from) / Float(frames) : 0
            for i in 0..<frames {
                mix[i] += scratch[i] * (from + slope * Float(i))
            }
        }

        limit(frames: frames)

        var sumSq: Double = 0
        for i in 0..<frames { sumSq += Double(mix[i]) * Double(mix[i]) }
        if os_unfair_lock_trylock(&stateLock) {
            outSumSquares += sumSq
            outSampleCount += frames
            os_unfair_lock_unlock(&stateLock)
        }

        // BlackHole 16ch: the mix leaves as duplicated stereo on channels 1-2,
        // the rest at zero. Teams/Zoom only take the aggregate's first two
        // channels; writing anywhere else would be invisible to them.
        for (index, buffer) in output.enumerated() {
            guard let raw = buffer.mData else { continue }
            let ptr = raw.assumingMemoryBound(to: Float.self)
            if index < 2 {
                ptr.update(from: mix, count: frames)
            } else {
                ptr.update(repeating: 0, count: frames)
            }
            if frames < frameCount {
                (ptr + frames).update(repeating: 0, count: frameCount - frames)
            }
        }
        return noErr
    }

    /// Soft-knee limiter on the mix, the equivalent of the JS
    /// `DynamicsCompressor` (threshold -6 dBFS, knee 6 dB, ratio 20, attack
    /// 2 ms, release 150 ms). The final clip at ±1 is a belt: the limiter lets
    /// through a transient shorter than its attack, the conversion downstream
    /// does not.
    private func limit(frames: Int) {
        for i in 0..<frames {
            let magnitude = abs(mix[i])
            envelope += (magnitude - envelope) * (magnitude > envelope ? attackCoef : releaseCoef)
            let envDb = 20 * log10f(max(envelope, 1e-9))
            let over = envDb - limiterThresholdDb
            var reduction: Float = 0
            if over >= limiterKneeDb / 2 {
                reduction = over * (1 - 1 / limiterRatio)
            } else if over > -limiterKneeDb / 2 {
                let t = over + limiterKneeDb / 2
                reduction = (1 - 1 / limiterRatio) * t * t / (2 * limiterKneeDb)
            }
            let y = mix[i] * gainFromDb(-reduction)
            mix[i] = min(max(y, -1), 1)
        }
    }
}
