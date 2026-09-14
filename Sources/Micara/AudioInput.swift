// AudioInput.swift — the Mac's mic, split out of Audio.swift: picking a real
// input device, bringing up the input-only AVAudioEngine on it, and pushing
// the tapped buffers into the local channel's ring.
//
// It lives apart because it is the half of the graph that drives the INPUT I/O
// unit: its own device-resolution rule (never capture Micara or BlackHole —
// that would be the mix capturing itself) and its own critical initialisation
// order. The tap does not run on the output's real-time thread, so unlike
// AudioOutput.swift this file is allowed to allocate.

import AVFoundation
import CoreAudio
import Foundation
import MicaraCore

extension AudioEngine {

    // MARK: - The Mac's mic

    func startInput(uid: String?) throws {
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
        var echoCancelled: Bool
        do {
            engine = try makeInputEngine(device: device, voiceProcessing: canUseAEC, channel: channel)
            echoCancelled = canUseAEC
        } catch {
            engine = try makeInputEngine(device: device, voiceProcessing: false, channel: channel)
            echoCancelled = false
        }
        channels[localChannelID] = channel
        publishChannels()
        inputEngine = engine
        adoptInput(name: device.name, echoCancelled: echoCancelled)
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

    func setDevice(_ id: AudioObjectID, on node: AVAudioIONode, what: String) throws {
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
}
