// Aggregate.swift — pure CoreAudio: the "Micara" aggregate device and the
// default input.
//
// A faithful port of `../bridge/native/micara-audio.c` (the C helper of the
// Electron bridge) and a replacement for `SwitchAudioSource`
// (`../bridge/lib/mic-setup.js`).
//
// WHY AN AGGREGATE: Teams/Zoom show the NAME of the input device. The BlackHole
// driver is called "BlackHole 16ch", and that name is compiled into the driver:
// renaming it would mean forking, recompiling and resigning it (an Apple
// Developer account). A CoreAudio aggregate device wrapping BlackHole 16ch
// gives the right name WITH NO privilege at all: an aggregate lives in the
// user's own audio settings (AudioHardwareCreateAggregateDevice), where
// installing a driver needs root.
//
// WHY NO MORE C BINARY AND NO MORE SwitchAudioSource: in Swift the HAL API is
// reachable straight from the app's process. No fork/exec, no JSON parsing, no
// third-party binary to ship and keep alive in the resources — and above all:
// the CoreAudio error comes back as it is (OSStatus) instead of a 0/1 exit
// code.
//
// INVARIANT KEPT FROM THE C: NEVER touch an aggregate we did not create. The
// identity is the UID `com.getmicara.bridge.aggregate`, NOT the displayed name
// (which the user can change in Audio MIDI Setup).

import CoreAudio
import Foundation

// MARK: - Errors

enum AudioDeviceError: Error, CustomStringConvertible {
    /// A HAL call failed. The `String` names the operation (useful in the log:
    /// an OSStatus alone does not say where it came from).
    case osStatus(OSStatus, String)
    case notFound(String)
    case blackHoleMissing

    var description: String {
        switch self {
        case let .osStatus(status, what):
            // CoreAudio OSStatus values are often FourCCs ('!obj', 'stop'…):
            // print both forms, otherwise the raw code is unreadable.
            return "CoreAudio \(what) failed (OSStatus \(status)\(Self.fourCC(status)))"
        case let .notFound(uid):
            return "No audio device with UID \"\(uid)\""
        case .blackHoleMissing:
            return "BlackHole 16ch is not installed"
        }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((UInt32(bitPattern: status) >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return " '\(String(decoding: bytes, as: UTF8.self))'"
    }
}

// MARK: - Device description

struct AudioDeviceInfo: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let isAggregate: Bool
}

// MARK: - HAL access

enum AudioDevices {

    // --- property-reading primitives (the C helpers' equivalents) ---

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Reads a CFString property (UID, name). `nil` when the device does not
    /// publish it — common and never fatal, filtered higher up.
    fileprivate static func string(
        _ device: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// Sum of the channels of every buffer of the device in a given scope —
    /// the same computation as `device_channels()` in the C (a device can
    /// expose several buffers, and counting only one underestimates the
    /// channels).
    fileprivate static func channels(
        _ device: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    fileprivate static func isAggregate(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeAggregate
    }

    fileprivate static func deviceIDs() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    // --- public API ---

    static func all() -> [AudioDeviceInfo] {
        deviceIDs().compactMap { id in
            // A device with no UID cannot be addressed in a stable way: skip it
            // rather than invent a key (the C let it through with an empty
            // string, which polluted the list).
            guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDeviceInfo(
                id: id,
                uid: uid,
                name: string(id, kAudioObjectPropertyName) ?? "",
                inputChannels: channels(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channels(id, scope: kAudioObjectPropertyScopeOutput),
                isAggregate: isAggregate(id)
            )
        }
    }

    static func find(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    /// UID of the device a system "default device" property points to.
    private static func defaultDeviceUID(_ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }

    static func defaultInputUID() -> String? {
        defaultDeviceUID(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// WHY the default output is exposed: the audio engine has to know where
    /// NOT to play. If the user set BlackHole as the system output, playing on
    /// "the default device" would feed the mix back into itself.
    static func defaultOutputUID() -> String? {
        defaultDeviceUID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func setDefaultInput(uid: String) throws {
        guard let device = find(uid: uid) else { throw AudioDeviceError.notFound(uid) }
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = device.id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &id
        )
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, "setDefaultInput(\(uid))")
        }
    }

    /// Listening token: as long as it is held, `handler` is called on every
    /// change to the device list. Its `deinit` removes the listener — the only
    /// safe way not to leave a block dangling in the HAL.
    final class ListenerToken {
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock

        fileprivate init(address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
            self.address = address
            self.block = block
        }

        deinit {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        }
    }

    /// Watches devices coming and going (BlackHole installed, headphones
    /// plugged in, an aggregate created by another process…). The callback
    /// lands on the main queue: the callers are the UI and the audio engine,
    /// both driven from the main thread.
    @discardableResult
    static func observeDeviceList(_ handler: @escaping () -> Void) -> AnyObject {
        var addr = address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        return ListenerToken(address: addr, block: block)
    }
}

// MARK: - The "Micara" aggregate

enum MicaraAggregate {
    static let uid = "com.getmicara.bridge.aggregate"
    static let name = "Micara"
    /// UID of the official BlackHole 16ch driver (a driver constant, stable
    /// since v0.2). Falls back to matching by name should the driver ever
    /// change its UID.
    static let blackHoleUID = "BlackHole16ch_UID"

    struct Status: Equatable {
        let present: Bool
        let healthy: Bool
        let blackHolePresent: Bool
        /// UID of the aggregate when it exists (to hand to `setDefaultInput`),
        /// `nil` otherwise.
        let deviceUID: String?
    }

    /// BlackHole usable by Micara: the official 16ch UID first, otherwise any
    /// device whose name contains "blackhole" WITHOUT "2ch" or "mirror".
    /// Project invariant (see `lib/mic-setup.js`): the 2ch is NEVER used.
    fileprivate static func findBlackHole() -> AudioDeviceInfo? {
        let devices = AudioDevices.all()
        if let exact = devices.first(where: { $0.uid == blackHoleUID }) { return exact }
        return devices.first { device in
            // Never stack an aggregate on an aggregate: one containing
            // BlackHole carries "blackhole" in its name and would become a
            // recursive sub-device.
            guard !device.isAggregate else { return false }
            let n = device.name.lowercased()
            return n.contains("blackhole")
                && !n.contains("2ch") && !n.contains("2 ch") && !n.contains("mirror")
        }
    }

    static var blackHoleInstalled: Bool { findBlackHole() != nil }

    /// Does the aggregate already contain this sub-device? ROBUSTNESS: if
    /// BlackHole was uninstalled then reinstalled, the aggregate can be empty →
    /// it would still appear in the Teams list but be MUTE, worse than no
    /// aggregate at all.
    private static func hasSubDevice(_ aggregate: AudioObjectID, uid: String) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var list: CFArray? = nil
        var size = UInt32(MemoryLayout<CFArray?>.size)
        let status = withUnsafeMutablePointer(to: &list) {
            AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let subs = list as? [Any] else { return false }
        // The list holds CFStrings (the sub-device UIDs); some macOS versions
        // put dictionaries describing the sub-device in it instead.
        return subs.contains { element in
            if let s = element as? String { return s == uid }
            if let d = element as? [String: Any], let s = d[kAudioSubDeviceUIDKey] as? String {
                return s == uid
            }
            return false
        }
    }

    static func status() -> Status {
        let blackHole = findBlackHole()
        guard let aggregate = AudioDevices.find(uid: uid) else {
            return Status(present: false, healthy: false,
                          blackHolePresent: blackHole != nil, deviceUID: nil)
        }
        let healthy = blackHole.map { hasSubDevice(aggregate.id, uid: $0.uid) } ?? false
        return Status(present: true, healthy: healthy,
                      blackHolePresent: blackHole != nil, deviceUID: aggregate.uid)
    }

    private static func createAggregate(blackHoleUID bhUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: bhUID]],
            kAudioAggregateDeviceMasterSubDeviceKey: bhUID,
            // IsPrivate=0: visible to EVERY app (Teams/Zoom) and not only to
            // the process that created it.
            kAudioAggregateDeviceIsPrivateKey: 0,
            // IsStacked=0: the sub-devices' channels are not stacked — with a
            // single sub-device the aggregate exposes BlackHole's 16 channels
            // in order (1↔1), which is what makes the mix written on channels
            // 1-2 come back out on channels 1-2 on the input side.
            kAudioAggregateDeviceIsStackedKey: 0,
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, "AudioHardwareCreateAggregateDevice")
        }
        return device
    }

    /// Waits until coreaudiod has published (or withdrawn) the aggregate in the
    /// global device list. WHY: `AudioHardwareCreate/DestroyAggregateDevice`
    /// returns as soon as coreaudiod has acknowledged, but the
    /// `kAudioHardwarePropertyDevices` property is updated asynchronously — an
    /// immediate `status()` could report `present:false` right after an
    /// `ensure()`. The C helper never hit this: it exited the process right
    /// after creating, and publication happened after its death. Here the
    /// process survives and asks: it has to wait.
    private static func waitForPublication(present expected: Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while (AudioDevices.find(uid: uid) != nil) != expected, Date() < deadline {
            // 25 ms: short enough not to slow "Start a Meeting" down, long
            // enough not to hammer the HAL.
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    /// Idempotent: creates the aggregate when missing, repairs it when it has
    /// lost BlackHole, and never touches an aggregate that is not ours
    /// (identity = UID).
    @discardableResult
    static func ensure() throws -> Status {
        guard let blackHole = findBlackHole() else { throw AudioDeviceError.blackHoleMissing }

        if let existing = AudioDevices.find(uid: uid) {
            if hasSubDevice(existing.id, uid: blackHole.uid) {
                return status()  // the C's "kept": nothing to do.
            }
            // Orphaned aggregate (BlackHole reinstalled under another UID, or
            // an aggregate created before the driver): destroy and rebuild it
            // rather than leave a mute device in the Teams list.
            let st = AudioHardwareDestroyAggregateDevice(existing.id)
            guard st == noErr else {
                throw AudioDeviceError.osStatus(st, "AudioHardwareDestroyAggregateDevice (repair)")
            }
            waitForPublication(present: false)
        }

        _ = try createAggregate(blackHoleUID: blackHole.uid)
        waitForPublication(present: true)
        return status()
    }

    /// Destroys ONLY the aggregate carrying our UID. Absent = silent success
    /// (the operation is idempotent, like the C's `remove`).
    static func remove() throws {
        guard let aggregate = AudioDevices.find(uid: uid) else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregate.id)
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, "AudioHardwareDestroyAggregateDevice")
        }
        waitForPublication(present: false)
    }
}

// MARK: - Default input, with restore

/// Switches the system default microphone to "Micara", and back.
///
/// Replaces `SwitchAudioSource` (`lib/mic-setup.js`): no third-party binary to
/// ship, and no picking by NAME (fragile: the user can rename a device, and two
/// devices can carry the same name). Here the identity is our aggregate's UID,
/// exactly as it is for its creation.
///
/// The remembered UID is persisted in UserDefaults: if the app dies between
/// `activate()` and `restore()`, the next launch can still hand the user back
/// the microphone they had before Micara.
final class DefaultInputSwitcher {
    private static let key = "previousInputUID"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Remembers the current microphone, then forces "Micara".
    /// WHY the "unless it is already Micara" guard: a double `activate()` (a
    /// meeting restarted without `restore()`, or a recovery after a crash)
    /// would overwrite the memory with "Micara" and the user would never get
    /// their microphone back.
    func activate() throws {
        let current = AudioDevices.defaultInputUID()
        if let current, current != MicaraAggregate.uid {
            defaults.set(current, forKey: Self.key)
        }
        try AudioDevices.setDefaultInput(uid: MicaraAggregate.uid)
    }

    /// Puts the old microphone back if it still exists; otherwise lets macOS
    /// choose (the system switches on its own when the default device
    /// disappears — forcing another device in its place would be more
    /// surprising than doing nothing). Never throws: `restore()` is called at
    /// the end of a meeting and on the error paths, it must not create a new
    /// error there.
    func restore() {
        defer { defaults.removeObject(forKey: Self.key) }
        guard let previous = defaults.string(forKey: Self.key),
              previous != MicaraAggregate.uid,
              AudioDevices.find(uid: previous) != nil else { return }
        try? AudioDevices.setDefaultInput(uid: previous)
    }
}
