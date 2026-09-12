// Micara — audio mixing: dominance + noise gate.
//
// 1:1 port of `bridge/renderer/mixer.cjs` (the pure module of the Electron
// bridge). Pure: no AppKit / AVFoundation / WebRTC dependency, so it stays
// testable without audio hardware or a server.

import Foundation

/// dBFS floor (digital silence). Matches `DB_MIN` in the JS module.
public let dbFloor: Float = -120

/// Linear gain for a value in dB (10^(dB/20)).
public func gainFromDb(_ db: Float) -> Float {
    powf(10, db / 20)
}

/// RMS of a sample buffer → dBFS, clamped to `dbFloor`.
///
/// The 1e-9 threshold avoids `log10(0)` = -inf on a strictly silent buffer: the
/// rest of the engine compares Floats, and one -inf would poison the averages.
public func rmsDb(_ samples: UnsafeBufferPointer<Float>) -> Float {
    if samples.isEmpty { return dbFloor }
    var sum: Float = 0
    for s in samples { sum += s * s }
    let rms = sqrtf(sum / Float(samples.count))
    if rms <= 1e-9 { return dbFloor }
    return max(20 * log10f(rms), dbFloor)
}

public func rmsDb(_ samples: [Float]) -> Float {
    samples.withUnsafeBufferPointer { rmsDb($0) }
}

/// Mixing mode, exposed in the menu bar menu.
/// "Dominance + gate" = the mixer below; "Sum" = gains at 1, with only the
/// output limiter guarding against clipping.
public enum MixMode: String, CaseIterable, Codable {
    case dominance
    case sum
}

/// Mixing constants — defaults are `MIX` from `renderer/src/engine.js`, tuned
/// in real meetings (see the comments in the JS).
public struct MixerConfig: Equatable {
    /// dBFS: gate opens (speech).
    public var gateOpenDb: Float
    /// dBFS: gate closes, lower than the opening (hysteresis against chatter).
    public var gateCloseDb: Float
    /// Hold before closing: without it, word endings get cut off.
    public var gateHoldMs: Double
    /// Attenuation of streams that are open but not dominant.
    public var duckDb: Float
    /// The challenger must beat the dominant by at least this much to take over.
    public var dominanceMarginDb: Float
    /// Minimum delay between two dominant switches.
    public var dominanceDwellMs: Double
    /// Gain rise towards the target (new dominant).
    public var attackSec: Float
    /// Gain fall towards the target (gate closing, former dominant).
    public var releaseSec: Float
    /// Level computation period.
    public var tickMs: Double
    /// Gain applied BEFORE level measurement: a phone lying 1-2 m away measures
    /// -66/-75 dBFS, so the -45 gate never opened. +10 dB and no more: +18 dB
    /// saturated the limiter ("distorted voice" — real feedback, 19/08).
    public var inputGainDb: Float

    public static let `default` = MixerConfig()

    public init(
        gateOpenDb: Float = -45,
        gateCloseDb: Float = -50,
        gateHoldMs: Double = 400,
        duckDb: Float = -18,
        dominanceMarginDb: Float = 3,
        dominanceDwellMs: Double = 300,
        attackSec: Float = 0.05,
        releaseSec: Float = 0.30,
        tickMs: Double = 50,
        inputGainDb: Float = 10
    ) {
        self.gateOpenDb = gateOpenDb
        self.gateCloseDb = gateCloseDb
        self.gateHoldMs = gateHoldMs
        self.duckDb = duckDb
        self.dominanceMarginDb = dominanceMarginDb
        self.dominanceDwellMs = dominanceDwellMs
        self.attackSec = attackSec
        self.releaseSec = releaseSec
        self.tickMs = tickMs
        self.inputGainDb = inputGainDb
    }
}

/// Measured level of one stream for a tick. `id` is opaque (a phoneId, or the
/// local mic's id, which the mixer treats like any other stream).
public struct LevelEntry: Equatable {
    public let id: String
    public let db: Float
    public init(id: String, db: Float) {
        self.id = id
        self.db = db
    }
}

/// Result of a tick: TARGET gains (0…1). The audio engine smooths them
/// (`GainSmoother`) — applying these raw values would produce clicks.
public struct TickResult: Equatable {
    public let gains: [String: Float]
    public let dominant: String?
    public let openCount: Int
    public init(gains: [String: Float], dominant: String?, openCount: Int) {
        self.gains = gains
        self.dominant = dominant
        self.openCount = openCount
    }
}

/// Dominance + noise gate mixer.
///
/// One stream "speaks" at gain 1; the other open streams are ducked by
/// `duckDb`, closed streams sit at 0. The anti-chatter rule (margin + dwell)
/// exists because without it two speakers at similar levels flip the dominant
/// on every tick (50 ms): since the attack (50 ms) ≈ the tick period and the
/// release is slow (300 ms), both gains stay half-way up and both mics stay
/// audible (observed on 18/08).
public final class DominanceMixer {
    private struct GateState {
        var open = false
        /// Last moment the stream was above the closing threshold.
        var lastOpenMs: Double = 0
    }

    public let config: MixerConfig
    private var states: [String: GateState] = [:]
    /// Current dominant, kept across ticks (this is what the dwell protects).
    public private(set) var dominantId: String?
    private var lastSwitchMs: Double = 0

    public init(config: MixerConfig = .default) {
        self.config = config
    }

    /// Computes the target gains for this tick. `nowMs` is the engine's clock.
    public func tick(_ entries: [LevelEntry], nowMs: Double) -> TickResult {
        // 1) per-stream gate: hysteresis + hold
        for e in entries {
            var st = states[e.id] ?? GateState()
            if !st.open {
                if e.db >= config.gateOpenDb {
                    st.open = true
                    st.lastOpenMs = nowMs
                }
            } else if e.db >= config.gateCloseDb {
                st.lastOpenMs = nowMs // above the low threshold → stay open
            } else if nowMs - st.lastOpenMs >= config.gateHoldMs {
                st.open = false
            }
            states[e.id] = st
        }

        // 2) dominance among the open streams, with anti-chatter.
        let open = entries.filter { states[$0.id]?.open == true }
        let openCount = open.count
        var dominant: String?
        if let first = open.first {
            var loudest = first
            for e in open where e.db > loudest.db { loudest = e }
            let cur = dominantId
            // The outgoing dominant only counts if it is still here AND open:
            // otherwise the seat is free and the loudest takes it right away.
            let curEntry = cur.flatMap { c in open.first { $0.id == c } }
            if let curEntry, let cur {
                if loudest.id == cur {
                    dominant = cur
                } else if nowMs - lastSwitchMs >= config.dominanceDwellMs
                    && loudest.db >= curEntry.db + config.dominanceMarginDb {
                    dominant = loudest.id // clearly louder AND the dwell elapsed
                } else {
                    dominant = cur // too close or too soon → keep it
                }
            } else {
                dominant = loudest.id
            }
        }
        if dominant != dominantId {
            dominantId = dominant
            lastSwitchMs = nowMs
        }

        // 3) target gains
        let duckGain = gainFromDb(config.duckDb)
        var gains: [String: Float] = [:]
        gains.reserveCapacity(entries.count)
        for e in entries {
            let isOpen = states[e.id]?.open == true
            gains[e.id] = isOpen ? (e.id == dominant ? 1 : duckGain) : 0
        }
        return TickResult(gains: gains, dominant: dominant, openCount: openCount)
    }

    /// Forgets a stream (phone disconnected) — avoids orphan states.
    /// If it was the dominant, the loudest takes over on the next tick.
    public func forget(id: String) {
        states.removeValue(forKey: id)
        if dominantId == id { dominantId = nil }
    }
}

/// One-pole exponential smoothing of a gain towards its target.
///
/// Replaces the Web Audio API's `setTargetAtTime`, which AVAudioEngine lacks:
/// applying the mixer's target gains as-is would click on every switch. On each
/// step of `dt` seconds:
///
///     g += (target - g) * (1 - exp(-dt / tau))
///
/// `tau` is `attackSec` when the target rises and `releaseSec` when it falls:
/// speech must open fast (50 ms) but close slowly (300 ms), otherwise word
/// endings sound chopped.
public struct GainSmoother {
    public var attackSec: Float
    public var releaseSec: Float
    /// Current gain (the smoother's state).
    public private(set) var value: Float

    public init(attackSec: Float = MixerConfig.default.attackSec,
                releaseSec: Float = MixerConfig.default.releaseSec,
                initial: Float = 0) {
        self.attackSec = attackSec
        self.releaseSec = releaseSec
        self.value = initial
    }

    @discardableResult
    public mutating func step(target: Float, dtSec: Float) -> Float {
        let tau = target > value ? attackSec : releaseSec
        // tau or dt at zero: no smoothing possible → jump straight (avoids a NaN).
        guard tau > 0, dtSec > 0 else {
            value = target
            return value
        }
        value += (target - value) * (1 - expf(-dtSec / tau))
        return value
    }

    /// Forces the gain with no smoothing (stream hooked up, meeting stopped).
    public mutating func reset(to newValue: Float) {
        value = newValue
    }
}
