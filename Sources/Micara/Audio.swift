// Audio.swift — the real-time engine: WebRTC tracks + the Mac's mic → mix → BlackHole.
//
// Port of `bridge/renderer/src/engine.js` (the Web Audio graph) to AVAudioEngine.
// Chain: remote track → LKRTCAudioRenderer → conversion to 48 kHz mono → ring
// buffer → a single AVAudioSourceNode (gate/dominance + smoothing + limiter) →
// channels 1-2 of BlackHole 16ch. The Mac's mic is a channel like any other
// (id `__local__`), never muted by `phonesMuted`, exactly like LOCAL_ID in the
// JS.
//
// ─────────────────────────────────────────────────────────────────────────────
// SILENCING WEBRTC PLAYOUT — RESULT OF THE SPIKE (12/09, measured on this machine)
// ─────────────────────────────────────────────────────────────────────────────
// The question: remote tracks must reach OUR mixer through the renderer, and
// WebRTC must NOT play them into the speakers itself. The spec's three options
// were tried in order, in a local loopback (two LKRTCPeerConnection in the same
// process):
//
//  1. NOT starting the ADM's playout (`stopPlayout` + `setEngineAvailability`
//     with `isOutputAvailable = false`) → THE RENDERER RECEIVES NOTHING AT ALL.
//     Measured: 400 buffers in 4 s with playout, 0 without. Consistent with
//     libwebrtc, where a REMOTE track's sink is fed from
//     `ChannelReceive::GetAudioFrameWithInfo`, called only by the playout loop
//     (the AudioMixer pulled by the ADM). No playout = no decoding = no PCM.
//     OPTION DISCARDED.
//
//  2. `track.source.volume = 0` → THE OPTION KEPT. Measured:
//       • the renderer keeps receiving 100 buffers/s, at full amplitude
//         (peak 0.13 at volume 0 against 0.12 at volume 1);
//       • what the ADM plays is DIGITAL SILENCE: playout redirected to
//         BlackHole 2ch and recorded from outside → -42.2 dB peak at volume 1,
//         -91 dB (the measurement floor) at volume 0.
//     In other words the output gain is applied AFTER delivery to the sink: we
//     keep the PCM intact and nothing leaves the speakers.
//
//  3. `trySetOutputDevice(BlackHole)`: not needed, and not available either —
//     this fork's `.audioEngine` ADM only exposes the system's default output
//     in `outputDevices` (BlackHole never shows up there). It would have been
//     wrong anyway: our AVAudioEngine already writes the phones into BlackHole,
//     and WebRTC would have written them there a second time.
//
// The factory is created with the `.audioEngine` ADM and
// `bypassVoiceProcessing = true` (see `SignalClient`): WebRTC's voice processing
// is useless here — the bridge SENDS no track, it only receives.
//
// ─────────────────────────────────────────────────────────────────────────────
// TWO AVAudioEngine, AND THE INPUT ONE STARTS FIRST
// ─────────────────────────────────────────────────────────────────────────────
// An AVAudioEngine drives only ONE I/O unit: setting
// `kAudioOutputUnitProperty_CurrentDevice` to output to BlackHole would set its
// input to BlackHole too — the Mac's "mic" would become our own mix (a loop).
// Hence two engines: `outputEngine` (source → BlackHole) and `inputEngine`
// (mic → tap).
//
// ORDER: the INPUT first. Bringing the input engine up reconfigures the I/O
// units and KILLS an output engine that is already running — measured: the
// output rendered 36 blocks (~0.4 s) then went silent for good, with no error
// and no notification. Input then output: 548 blocks in 5 s, meter at 0.6,
// BlackHole recorded at -34 dB peak.
//
// The captured mic is NEVER "the default input device" taken blindly: during a
// meeting the default IS the Micara aggregate (so, BlackHole). We pick a real
// mic explicitly (`resolveInputDevice`) — at the cost of AEC when that mic is
// not the system default, see `startInput`.

import AVFoundation
import CoreAudio
import Foundation
import LiveKitWebRTC
import MicaraCore

// MARK: - Constants

/// Id of the Mac's mic inside the mixer — same value as `LOCAL_ID` in the JS
/// (the mixer treats it like any other stream: it can become dominant).
let localChannelID = "__local__"

/// All mixing happens at 48 kHz mono: that is WebRTC's output rate and
/// BlackHole's. One rate in the graph = one conversion, at each channel's
/// input.
private let mixSampleRate: Double = 48_000

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

/// Window of the level meter and of the mixing tick (`MIX.tickMs` in the JS).
private let tickSec: Double = 0.05

// MARK: - Per-channel ring buffer

/// `MonoRing` (MicaraCore, tested): one producer (the WebRTC thread or the mic
/// tap), one consumer (the CoreAudio thread), FIFO order guaranteed.
private typealias Ring = MonoRing

// MARK: - Channel

/// One stream in the mix: the ring fed by WebRTC (or by the mic), the
/// smoothing state (audio thread only) and the mailbox shared with the tick.
private final class Channel {
    let id: String
    let isLocal: Bool
    let ring = Ring(capacity: Int(mixSampleRate / 2))  // 500 ms

    /// Audio-thread state EXCLUSIVELY: nobody else touches it.
    var smoother = GainSmoother()

    // Mailbox between the audio thread and the tick, under a lock held for a
    // few nanoseconds (two Doubles and a Float).
    private var lock = os_unfair_lock_s()
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private var target: Float = 0

    init(id: String, isLocal: Bool) {
        self.id = id
        self.isLocal = isLocal
    }

    /// Audio thread → tick: level measured AFTER the input gain (like the JS,
    /// where the analyser sits after `inputGain`).
    func accumulate(sumSquares s: Double, count: Int) {
        os_unfair_lock_lock(&lock)
        sumSquares += s
        sampleCount += count
        os_unfair_lock_unlock(&lock)
    }

    /// Tick → reads and clears the window. `nil` if no sample went through (a
    /// brand-new channel): no measurement = no level entry.
    func drainLevelDb() -> Float? {
        os_unfair_lock_lock(&lock)
        let s = sumSquares, n = sampleCount
        sumSquares = 0
        sampleCount = 0
        os_unfair_lock_unlock(&lock)
        guard n > 0 else { return nil }
        let rms = (s / Double(n)).squareRoot()
        if rms <= 1e-9 { return dbFloor }
        return max(Float(20 * log10(rms)), dbFloor)
    }

    var targetGain: Float {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return target
        }
        set {
            os_unfair_lock_lock(&lock)
            target = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}

// MARK: - Renderer for a remote track

/// Receives the PCM of an `LKRTCAudioTrack` (WebRTC's thread, not the CoreAudio
/// one), converts it to 48 kHz mono Float32 and pushes it into the ring.
///
/// The conversion happens HERE, off the real-time thread: it is the only place
/// where allocating cannot cause an output glitch.
private final class TrackRenderer: NSObject, LKRTCAudioRenderer {
    private weak var channel: Channel?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: mixSampleRate,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?

    /// Diagnostic counter (spike + log): proves the PCM is arriving.
    private(set) var bufferCount: Int = 0

    init(channel: Channel) {
        self.channel = channel
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let channel else { return }
        bufferCount += 1
        guard let mono = convert(pcmBuffer), let data = mono.floatChannelData else { return }
        channel.ring.write(data[0], count: Int(mono.frameLength))
    }

    /// Brings whatever format WebRTC delivers (Int16/Float32, 1 or 2 channels,
    /// 48 kHz in practice) to the mix format. The converter is rebuilt if the
    /// format changes along the way.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let inFormat = buffer.format
        if inFormat == targetFormat { return buffer }
        if converter == nil || converterInputFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: targetFormat)
            converterInputFormat = inFormat
            scratch = nil
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        if scratch == nil || scratch!.frameCapacity < capacity {
            scratch = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let out = scratch else { return nil }
        out.frameLength = 0
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

// MARK: - Audio-thread state

/// Everything the render block touches. A separate object (rather than
/// `AudioEngine`) so the block can capture it strongly without creating a cycle
/// with the engine.
private final class Mixdown {
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
        guard n > 0 else { return nil }
        let rms = (s / Double(n)).squareRoot()
        if rms <= 1e-9 { return dbFloor }
        return max(Float(20 * log10(rms)), dbFloor)
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

// MARK: - Engine

enum AudioEngineError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case noInputDevice
    case coreAudio(OSStatus, String)

    var description: String {
        switch self {
        case let .deviceNotFound(uid): return "Output device not found: \"\(uid)\""
        case .noInputDevice: return "No usable mic (BlackHole / Micara aggregate excluded)"
        case let .coreAudio(status, what): return "\(what) failed (OSStatus \(status))"
        }
    }
}

final class AudioEngine {

    // MARK: public state

    var mode: MixMode {
        get { mixdown.mode }
        set { mixdown.mode = newValue }
    }

    /// Gain 0 on EVERY phone; the Mac's mic keeps going (spec, rule 6).
    var phonesMuted: Bool {
        get { mixdown.phonesMuted }
        set { mixdown.phonesMuted = newValue }
    }

    /// Level of the final mix, 0…1, on the main queue, ~20 Hz.
    var onLevel: ((Float) -> Void)?

    private(set) var isRunning = false

    // MARK: internal state

    private let config: MixerConfig
    private let mixer: DominanceMixer
    private let mixdown: Mixdown

    /// Serial queue that owns the channel table and the tick. The audio thread
    /// never touches it: it reads a snapshot published by `Mixdown`.
    private let queue = DispatchQueue(label: "com.getmicara.audio.control")
    /// Marks `queue` so `onQueue` can tell whether it is already running on
    /// it. WHY: `deinit` calls `stop()`, and the last reference to the engine
    /// can be released FROM the queue itself (a `queue.async { [self] … }`
    /// block being disposed after the meeting ended). A `queue.sync` from
    /// there is a deadlock, which libdispatch turns into a crash — measured
    /// live (12/09): "dispatch_sync called on queue already owned by current
    /// thread", at the end of every meeting once a phone had joined.
    private static let queueKey = DispatchSpecificKey<Void>()
    private var channels: [String: Channel] = [:]
    private var renderers: [String: TrackRenderer] = [:]
    private var tracks: [String: LKRTCAudioTrack] = [:]

    private var outputEngine: AVAudioEngine?
    private var inputEngine: AVAudioEngine?
    /// What `start` was asked for, so a configuration change can rebuild the
    /// same graph.
    private var requestedOutputUID: String?
    private var requestedInputUID: String?
    private var configurationObservers: [NSObjectProtocol] = []
    private var pendingRebuild: DispatchWorkItem?
    private var sourceNode: AVAudioSourceNode?
    private var tickTimer: DispatchSourceTimer?
    private var inputConverter: AVAudioConverter?
    private var inputConverterFormat: AVAudioFormat?
    /// Mono buffer reused by the mic tap (no allocation per buffer).
    private var localMono: [Float] = []

    /// Current dominant (diagnostics / log), published by the tick.
    private(set) var dominantID: String?
    /// The mic actually captured — `nil` if none (TCC permission refused, or
    /// only BlackHole available). The UI must be able to tell the user.
    private(set) var inputDeviceName: String?
    /// Is AEC really active on the mic? False when the wanted mic is not the
    /// system's default input (a VPIO limitation, cf. `startInput`) — the UI and
    /// the log must be able to say so.
    private(set) var inputEchoCancelled = false

    init(config: MixerConfig = .default) {
        self.config = config
        mixer = DominanceMixer(config: config)
        mixdown = Mixdown(config: config)
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    /// Runs `body` on `queue`, inline when already there (see `queueKey`).
    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }

    deinit { stop() }

    // MARK: - Start / stop

    /// Starts the graph: input = a real mic (AEC on), output = the device with
    /// the given UID. `inputDeviceUID` is for tests; in production it is left
    /// `nil` and the engine picks (see `resolveInputDevice`).
    func start(outputDeviceUID: String, inputDeviceUID: String? = nil) throws {
        try onQueue {
            guard !isRunning else { return }
            requestedOutputUID = outputDeviceUID
            requestedInputUID = inputDeviceUID
            // INPUT FIRST: bringing the input engine up reconfigures the I/O
            // unit and brings down an output engine that already started
            // (measured at the spike: the output rendered ~36 blocks then went
            // quiet). A missing or refused mic (TCC) must NOT block the meeting:
            // the phones are the point, the Mac's mic is a bonus.
            do { try startInput(uid: inputDeviceUID) } catch {
                inputEngine = nil
                inputDeviceName = nil
                AppLog.write("[audio] Mac mic NOT captured: \(error)")
            }
            if let name = inputDeviceName {
                AppLog.write("[audio] Mac mic: \(name), echo cancellation \(inputEchoCancelled ? "on" : "off")")
            }
            try startOutput(uid: outputDeviceUID)
            AppLog.write("[audio] output: \(AudioDevices.find(uid: outputDeviceUID)?.name ?? outputDeviceUID)")
            startTick()
            isRunning = true
        }
    }

    func stop() {
        onQueue {
            guard isRunning || outputEngine != nil || inputEngine != nil else { return }
            tickTimer?.cancel()
            tickTimer = nil
            pendingRebuild?.cancel()
            pendingRebuild = nil
            configurationObservers.forEach(NotificationCenter.default.removeObserver)
            configurationObservers.removeAll()

            inputEngine?.inputNode.removeTap(onBus: 0)
            inputEngine?.stop()
            inputEngine = nil
            inputDeviceName = nil
            inputEchoCancelled = false

            outputEngine?.stop()
            if let node = sourceNode, let engine = outputEngine {
                engine.detach(node)
            }
            sourceNode = nil
            outputEngine = nil

            for (id, renderer) in renderers {
                tracks[id]?.remove(renderer)
            }
            renderers.removeAll()
            tracks.removeAll()
            for id in channels.keys { mixer.forget(id: id) }
            channels.removeAll()
            mixdown.publish(channels: [])
            isRunning = false
        }
    }

    // MARK: - Phones

    /// Attaches a renderer to the remote track and creates its channel. Called
    /// as soon as the track exists, WITHOUT waiting for `ICE connected`: on
    /// Chromium, `ontrack` precedes ICE establishment (a trap documented in
    /// `engine.js`) and waiting would miss the start of speech.
    func addPhone(id: String, track: LKRTCAudioTrack) {
        queue.async { [self] in
            guard channels[id] == nil else { return }
            let channel = Channel(id: id, isLocal: false)
            channel.smoother = GainSmoother(attackSec: config.attackSec, releaseSec: config.releaseSec)
            let renderer = TrackRenderer(channel: channel)
            // Option 2 from the spike: the PCM keeps reaching the renderer,
            // but WebRTC no longer plays anything into the speakers.
            track.source.volume = 0
            track.add(renderer)
            channels[id] = channel
            renderers[id] = renderer
            tracks[id] = track
            publishChannels()
        }
    }

    func removePhone(id: String) {
        queue.async { [self] in
            if let renderer = renderers.removeValue(forKey: id) {
                tracks[id]?.remove(renderer)
            }
            tracks.removeValue(forKey: id)
            channels.removeValue(forKey: id)
            mixer.forget(id: id)
            if dominantID == id { dominantID = nil }
            publishChannels()
        }
    }

    /// Diagnostics (log, telemetry): per channel, the number of PCM buffers
    /// received since attaching and the peak written since the last call. The
    /// two together tell "nothing is arriving" from "it arrives silent".
    /// Blocks rendered by the output node since start-up.
    var renderedBlocks: Int { mixdown.renderCount }

    func diagnostics() -> [String: (buffers: Int, peak: Float)] {
        onQueue {
            var out: [String: (buffers: Int, peak: Float)] = [:]
            for (id, channel) in channels {
                out[id] = (renderers[id]?.bufferCount ?? 0, channel.ring.drainPeak())
            }
            return out
        }
    }

    // MARK: - Output graph

    private func startOutput(uid: String) throws {
        guard let device = AudioDevices.find(uid: uid) else {
            throw AudioEngineError.deviceNotFound(uid)
        }
        let engine = AVAudioEngine()
        // Set the device BEFORE reading the format: the chosen device's format
        // is what must dictate the channel count (16 for BlackHole), not the
        // default output's.
        try setDevice(device.id, on: engine.outputNode, what: "output")

        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let channelCount = max(hardware.channelCount, 2)
        let sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : mixSampleRate
        // Past 2 channels, AVAudioFormat DEMANDS an explicit layout: the
        // "commonFormat" initialiser returns nil, and BlackHole has 16.
        // `DiscreteInOrder` = no role (left/right/LFE…), the channels are
        // numbered — exactly what the aggregate exposes to Teams.
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
        ) else {
            throw AudioEngineError.coreAudio(-1, "output format with \(channelCount) channels")
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)

        let mixdown = self.mixdown
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            return mixdown.render(frameCount: Int(frameCount), output: buffers)
        }
        engine.attach(node)
        engine.connect(node, to: engine.outputNode, format: format)
        engine.prepare()
        try engine.start()
        observeConfigurationChanges(of: engine)

        outputEngine = engine
        sourceNode = node
    }

    // MARK: - Configuration changes

    /// AVAudioEngine STOPS ITSELF whenever the system's default device changes,
    /// even with the I/O unit pinned to another device, and only posts a
    /// notification. Measured in the real app (12/09): the output rendered 4
    /// blocks, then nothing, the moment Micara became the default input. The
    /// graph is rebuilt on the same devices; phone channels are kept, only the
    /// engines and the local channel are recreated. Both engines post, so the
    /// rebuild is coalesced.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.scheduleRebuild() }
        configurationObservers.append(token)
    }

    private func scheduleRebuild() {
        queue.async { [self] in
            guard isRunning else { return }
            pendingRebuild?.cancel()
            let work = DispatchWorkItem { [self] in self.rebuildEngines() }
            pendingRebuild = work
            queue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    /// On `queue`. The notification also fires while both engines keep running
    /// (measured: 50 in 15 s once the pinned mic differs from the default
    /// input), so only a graph that actually stopped is rebuilt — rebuilding a
    /// live one recreates the channels, which posts again, which loops.
    private func rebuildEngines() {
        guard isRunning, let outputUID = requestedOutputUID else { return }
        let outputDead = outputEngine.map { !$0.isRunning } ?? true
        let inputDead = inputEngine.map { !$0.isRunning } ?? false
        guard outputDead || inputDead else { return }
        AppLog.write("[audio] configuration changed, rebuilding the graph (output \(outputDead ? "stopped" : "running"), mic \(inputDead ? "stopped" : "running"))")
        configurationObservers.forEach(NotificationCenter.default.removeObserver)
        configurationObservers.removeAll()
        inputEngine?.inputNode.removeTap(onBus: 0)
        inputEngine?.stop()
        inputEngine = nil
        outputEngine?.stop()
        if let node = sourceNode, let engine = outputEngine { engine.detach(node) }
        sourceNode = nil
        outputEngine = nil
        do { try startInput(uid: requestedInputUID) } catch {
            AppLog.write("[audio] rebuild: Mac mic NOT captured: \(error)")
        }
        do { try startOutput(uid: outputUID) } catch {
            AppLog.write("[audio] rebuild: output failed: \(error)")
        }
    }

    // MARK: - The Mac's mic

    private func startInput(uid: String?) throws {
        guard let device = try resolveInputDevice(uid: uid) else {
            throw AudioEngineError.noInputDevice
        }
        let channel = Channel(id: localChannelID, isLocal: true)
        channel.smoother = GainSmoother(attackSec: config.attackSec, releaseSec: config.releaseSec)

        // AEC (the equivalent of Chromium's `echoCancellation: true`): possible
        // ONLY if the wanted mic is already the system's default input.
        // Measured at the spike: `setVoiceProcessingEnabled(true)` brings the
        // VPIO up on the DEFAULT INPUT and overwrites the device we had just
        // forced (read back afterwards: 132 instead of 138). And forcing the
        // device AFTER enabling it fails (-10875) every single time. So: AEC
        // when the default is the right mic, capture without AEC otherwise.
        // Never invert that priority — capturing BlackHole by mistake loops the
        // mix onto itself.
        // Measured in the real app (12/09): with the VPIO on, the output engine
        // rendered 4 blocks and went silent for good the moment Micara became
        // the default input, and the mic tap died with it. The VPIO tracks the
        // default device and takes the shared I/O down with it. Echo
        // cancellation is therefore OFF; Teams/Zoom run their own AEC on the
        // Micara input anyway. Flip `aecAllowed` to try again after a change.
        let aecAllowed = false
        let canUseAEC = aecAllowed && AudioDevices.defaultInputUID() == device.uid
        var engine: AVAudioEngine
        do {
            engine = try makeInputEngine(device: device, voiceProcessing: canUseAEC, channel: channel)
            inputEchoCancelled = canUseAEC
        } catch {
            engine = try makeInputEngine(device: device, voiceProcessing: false, channel: channel)
            inputEchoCancelled = false
        }
        channels[localChannelID] = channel
        publishChannels()
        inputEngine = engine
        inputDeviceName = device.name
    }

    /// Brings up an input-only engine on a specific device.
    ///
    /// CRITICAL ORDER, found at the spike (any other sequence gives a tap that
    /// NEVER fires, without the slightest error, or a unit that refuses to
    /// initialise):
    ///   1. `AudioUnitUninitialize` — you cannot change the device of an
    ///      already-initialised unit: the property is ACCEPTED (status 0) and
    ///      the tap stays silent forever;
    ///   2. `kAudioOutputUnitProperty_CurrentDevice`;
    ///   3. `AudioUnitInitialize`;
    ///   4. `setVoiceProcessingEnabled` LAST (calling it earlier makes
    ///      initialisation on the forced device fail);
    ///   5. tap format = `inputFormat(forBus:)`, the HARDWARE format. With
    ///      `outputFormat` or `nil`, no callback ever arrives.
    ///
    /// With the VPIO, the input bus exposes 5 channels CARRYING THE SAME SIGNAL
    /// (measured: identical RMS to a tenth of a dB across all 5): taking
    /// channel 0 is right, and letting `AVAudioConverter` "mix down" those 5
    /// channels is not (see `pushLocal`).
    private func makeInputEngine(
        device: AudioDeviceInfo, voiceProcessing: Bool, channel: Channel
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            throw AudioEngineError.coreAudio(-1, "input audio unit")
        }
        _ = AudioUnitUninitialize(unit)
        var deviceID = device.id
        let set = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard set == noErr else {
            throw AudioEngineError.coreAudio(set, "input device \(device.name)")
        }
        let initialized = AudioUnitInitialize(unit)
        guard initialized == noErr else {
            throw AudioEngineError.coreAudio(initialized, "AudioUnitInitialize (input)")
        }
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioEngineError.coreAudio(-1, "empty input format")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.pushLocal(buffer, into: channel)
        }
        engine.prepare()
        try engine.start()
        observeConfigurationChanges(of: engine)
        return engine
    }

    /// Converts the mic's buffer to 48 kHz mono and pushes it into the ring.
    /// The tap does not run on the output's CoreAudio thread: allocating the
    /// converter here has no consequence for rendering.
    /// WHY NOT let `AVAudioConverter` do the channel reduction: with the VPIO
    /// active, the Mac's mic arrives as 5 channels with no standard layout;
    /// `AVAudioConverter` then refuses the conversion silently (no error
    /// reported, zero frames produced — the mic stayed mute at the spike). So we
    /// extract channel 0 ourselves, and the converter only resamples mono →
    /// mono.
    private func pushLocal(_ buffer: AVAudioPCMBuffer, into channel: Channel) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let sourceRate = buffer.format.sampleRate
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1

        if localMono.count < frames { localMono = [Float](repeating: 0, count: frames * 2) }
        localMono.withUnsafeMutableBufferPointer { mono in
            let src = data[0]
            for i in 0..<frames { mono[i] = src[i * stride] }
        }

        if sourceRate == mixSampleRate {
            localMono.withUnsafeBufferPointer { channel.ring.write($0.baseAddress!, count: frames) }
            return
        }

        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sourceRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: mixSampleRate, channels: 1, interleaved: false)
        else { return }
        if inputConverter == nil || inputConverterFormat != source {
            inputConverter = AVAudioConverter(from: source, to: target)
            inputConverterFormat = source
        }
        guard let converter = inputConverter,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        input.frameLength = AVAudioFrameCount(frames)
        localMono.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: frames)
        }
        let capacity = AVAudioFrameCount(Double(frames) * mixSampleRate / sourceRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let converted = out.floatChannelData, out.frameLength > 0 else { return }
        channel.ring.write(converted[0], count: Int(out.frameLength))
    }

    /// Picks the mic. NEVER "the default input device" without checking it:
    /// during a meeting the default is the Micara aggregate, whose input is
    /// BlackHole — that is, OUR OWN MIX. Capturing ourselves would build a loop
    /// that climbs to the limiter within seconds.
    private func resolveInputDevice(uid: String?) throws -> AudioDeviceInfo? {
        let devices = AudioDevices.all().filter { $0.inputChannels > 0 }
        let forbidden: (AudioDeviceInfo) -> Bool = { device in
            device.uid == MicaraAggregate.uid
                || device.isAggregate
                || device.name.lowercased().contains("blackhole")
        }
        if let uid {
            guard let forced = devices.first(where: { $0.uid == uid }) else {
                throw AudioEngineError.deviceNotFound(uid)
            }
            // Even a caller's explicit choice is checked: after a crash
            // mid-meeting the system default is still Micara, and the caller
            // may hand it over in good faith. Measured live (12/09): "Mac mic:
            // Micara" — the mix captured itself.
            if !forbidden(forced) { return forced }
            AppLog.write("[audio] requested mic \(forced.name) is Micara/BlackHole itself, picking another one")
        }
        if let current = AudioDevices.defaultInputUID(),
           let device = devices.first(where: { $0.uid == current }),
           !forbidden(device) {
            return device
        }
        return devices.first { !forbidden($0) }
    }

    private func setDevice(_ id: AudioObjectID, on node: AVAudioIONode, what: String) throws {
        guard let unit = node.audioUnit else {
            throw AudioEngineError.coreAudio(-1, "\(what) audio unit")
        }
        // An already-initialised I/O unit refuses a device change: at the
        // spike, the 3rd `start()` in a row failed with 'nope'
        // (kAudioHardwareIllegalOperationError) while the first two went
        // through. Uninitialising first makes the operation reproducible.
        _ = AudioUnitUninitialize(unit)
        defer { _ = AudioUnitInitialize(unit) }
        var deviceID = id
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw AudioEngineError.coreAudio(status, "kAudioOutputUnitProperty_CurrentDevice (\(what))")
        }
    }

    // MARK: - Tick

    private func publishChannels() {
        mixdown.publish(channels: Array(channels.values))
    }

    /// WHY a timer rather than the render block: `DominanceMixer.tick`
    /// allocates (a gains dictionary, an array of open streams) and the
    /// CoreAudio thread may neither allocate nor take a long lock. So the audio
    /// thread publishes per-channel sums of squares; this timer drains them
    /// every 50 ms (`MIX.tickMs`), calls the mixer, and hands back to the audio
    /// thread only one Float per channel. The smoothing stays on the audio
    /// thread, the only place where `dt` is exact.
    private func startTick() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tickSec, repeating: tickSec, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    private func tick() {
        let nowMs = Date().timeIntervalSince1970 * 1000
        var levels: [LevelEntry] = []
        levels.reserveCapacity(channels.count)
        for channel in channels.values {
            guard let db = channel.drainLevelDb() else { continue }
            levels.append(LevelEntry(id: channel.id, db: db))
        }

        switch mixdown.mode {
        case .sum:
            // "Sum": everybody at 1, the limiter alone protects (spec).
            for channel in channels.values { channel.targetGain = 1 }
            dominantID = nil
        case .dominance:
            let result = mixer.tick(levels, nowMs: nowMs)
            for channel in channels.values {
                channel.targetGain = result.gains[channel.id] ?? channel.targetGain
            }
            dominantID = result.dominant
        }

        if let db = mixdown.drainOutputDb(), let onLevel {
            // Perceptual scale: -60 dB → 0, 0 dB → 1. Below -60 dB, a meter
            // linear in amplitude stops moving altogether.
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
