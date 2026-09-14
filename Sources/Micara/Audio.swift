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
let mixSampleRate: Double = 48_000

/// Window of the level meter and of the mixing tick (`MIX.tickMs` in the JS).
private let tickSec: Double = 0.05

// MARK: - Per-channel ring buffer

/// `MonoRing` (MicaraCore, tested): one producer (the WebRTC thread or the mic
/// tap), one consumer (the CoreAudio thread), FIFO order guaranteed.
/// Internal, not private: `Channel.ring` is read by the render block in
/// AudioOutput.swift.
typealias Ring = MonoRing

// MARK: - Channel

/// One stream in the mix: the ring fed by WebRTC (or by the mic), the
/// smoothing state (audio thread only) and the mailbox shared with the tick.
final class Channel {
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

    let config: MixerConfig
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
    var channels: [String: Channel] = [:]
    private var renderers: [String: TrackRenderer] = [:]
    private var tracks: [String: LKRTCAudioTrack] = [:]

    private var outputEngine: AVAudioEngine?
    var inputEngine: AVAudioEngine?
    /// What `start` was asked for, so a configuration change can rebuild the
    /// same graph.
    private var requestedOutputUID: String?
    private var requestedInputUID: String?
    private var configurationObservers: [NSObjectProtocol] = []
    private var pendingRebuild: DispatchWorkItem?
    private var sourceNode: AVAudioSourceNode?
    private var tickTimer: DispatchSourceTimer?
    var inputConverter: AVAudioConverter?
    var inputConverterFormat: AVAudioFormat?
    /// Mono buffer reused by the mic tap (no allocation per buffer).
    var localMono: [Float] = []

    /// Current dominant (diagnostics / log), published by the tick.
    private(set) var dominantID: String?
    /// The mic actually captured — `nil` if none (TCC permission refused, or
    /// only BlackHole available). The UI must be able to tell the user.
    private(set) var inputDeviceName: String?
    /// Is AEC really active on the mic? False when the wanted mic is not the
    /// system's default input (a VPIO limitation, cf. `startInput`) — the UI and
    /// the log must be able to say so.
    private(set) var inputEchoCancelled = false

    /// The only way to write the two properties above, so that the rest of the
    /// module keeps reading them and nothing else sets them. `startInput`
    /// (AudioInput.swift) is in another file, hence not a `private` setter.
    func adoptInput(name: String?, echoCancelled: Bool) {
        inputDeviceName = name
        inputEchoCancelled = echoCancelled
    }

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
                adoptInput(name: nil, echoCancelled: false)
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
            adoptInput(name: nil, echoCancelled: false)

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
    func observeConfigurationChanges(of engine: AVAudioEngine) {
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

    // MARK: - Tick

    func publishChannels() {
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
