// The checks from `bridge/test-mixer.mjs`, carried over: the Swift port must
// make exactly the same decisions as the JS module does in production.
//
// swift-testing rather than XCTest: this machine only has the Command Line
// Tools, which ship no XCTest.framework (only Testing.framework).

import Foundation
import Testing
@testable import MicaraCore

@Suite("rmsDb")
struct RmsDbTests {
    @Test func digitalSilenceGivesTheFloor() {
        #expect(rmsDb([Float](repeating: 0, count: 1024)) == dbFloor)
    }

    @Test func fullScaleSineGivesAboutMinus3dB() {
        let n = 1024
        let sine = (0..<n).map { Float(sin(Double($0) / Double(n) * 2 * Double.pi)) }
        #expect(rmsDb(sine).rounded() == -3)
    }

    @Test func emptyBufferGivesTheFloor() {
        #expect(rmsDb([Float]()) == dbFloor)
    }

    // `meanSquareDb` is the same measurement for the accumulating meters (the
    // per-channel one and the mix one). It must agree with `rmsDb` on the same
    // signal, and it must tell "nothing went through" apart from "silence".
    @Test func accumulatedNothingIsNotSilence() {
        #expect(meanSquareDb(sumSquares: 0, count: 0) == nil)
        #expect(meanSquareDb(sumSquares: 0, count: 1024) == dbFloor)
    }

    @Test func accumulatedSineMatchesTheBufferMeasurement() {
        let n = 1024
        let sine = (0..<n).map { Float(sin(Double($0) / Double(n) * 2 * Double.pi)) }
        let sumSquares = sine.reduce(0.0) { $0 + Double($1) * Double($1) }
        let accumulated = meanSquareDb(sumSquares: sumSquares, count: n)
        #expect(accumulated != nil)
        #expect(abs(accumulated! - rmsDb(sine)) < 1e-4)
    }

    @Test func gainFromDecibels() {
        #expect(abs(gainFromDb(0) - 1) < 1e-6)
        #expect(abs(gainFromDb(-6) - 0.5011872) < 1e-6)
        #expect(abs(gainFromDb(-18) - 0.12589254) < 1e-6)
    }
}

@Suite("Gate")
struct GateTests {
    @Test func hysteresisAndHold() {
        let m = DominanceMixer(config: MixerConfig(gateOpenDb: -45, gateCloseDb: -50, gateHoldMs: 400))

        var r = m.tick([LevelEntry(id: "a", db: -60)], nowMs: 0)
        #expect(r.gains["a"] == 0)      // below the opening threshold
        #expect(r.openCount == 0)

        r = m.tick([LevelEntry(id: "a", db: -44)], nowMs: 100)
        #expect(r.gains["a"] == 1)      // speech (-44 ≥ -45) → open
        #expect(r.openCount == 1)

        r = m.tick([LevelEntry(id: "a", db: -48)], nowMs: 200)
        #expect(r.gains["a"] == 1)      // hysteresis: -48 ≥ -50 → stays open

        r = m.tick([LevelEntry(id: "a", db: -60)], nowMs: 250)
        #expect(r.gains["a"] == 1)      // the 400 ms hold has not elapsed

        r = m.tick([LevelEntry(id: "a", db: -60)], nowMs: 700)
        #expect(r.gains["a"] == 0)      // hold elapsed → closes
    }
}

@Suite("Dominance")
struct DominanceTests {
    @Test func dominanceDuckingMarginDwellAndForget() throws {
        let d = DominanceMixer(config: MixerConfig(duckDb: -18))

        var r = d.tick([LevelEntry(id: "a", db: -30), LevelEntry(id: "b", db: -35)], nowMs: 0)
        #expect(r.gains["a"] == 1)                                  // the loudest speaks
        #expect((20 * log10(try #require(r.gains["b"]))).rounded() == -18) // the other is ducked
        #expect(r.dominant == "a")

        r = d.tick([LevelEntry(id: "a", db: -41), LevelEntry(id: "b", db: -40)], nowMs: 50)
        #expect(r.dominant == "a")  // b leads by < 3 dB → no switch

        r = d.tick([LevelEntry(id: "a", db: -60), LevelEntry(id: "b", db: -35)], nowMs: 100)
        #expect(r.dominant == "a")  // margin met, the 300 ms dwell has not elapsed

        r = d.tick([LevelEntry(id: "a", db: -60), LevelEntry(id: "b", db: -35)], nowMs: 450)
        #expect(r.dominant == "b")  // dwell elapsed + margin → switch

        r = d.tick([LevelEntry(id: "a", db: -80), LevelEntry(id: "b", db: -80)], nowMs: 900)
        #expect(r.gains["a"] == 0)
        #expect(r.gains["b"] == 0)
        #expect(r.dominant == nil)

        d.forget(id: "b")
        r = d.tick([LevelEntry(id: "a", db: -30)], nowMs: 1000)
        #expect(r.gains["b"] == nil)   // a forgotten stream is absent from the gains
        #expect(r.dominant == "a")     // the dominant is gone → the loudest takes over
    }

    @Test func forgettingTheDominantFreesTheSeatWithoutWaitingForTheDwell() {
        let d = DominanceMixer()
        _ = d.tick([LevelEntry(id: "a", db: -30), LevelEntry(id: "b", db: -32)], nowMs: 0)
        #expect(d.dominantId == "a")
        d.forget(id: "a")
        // b has neither the margin nor the dwell: it takes over because the seat
        // is empty — the JS behaviour after `removeChannel`.
        #expect(d.tick([LevelEntry(id: "b", db: -32)], nowMs: 50).dominant == "b")
    }

    @Test func mixModeIsAStableEnumBecauseItIsPersistedInTheSettings() {
        #expect(MixMode(rawValue: "sum") == .sum)
        #expect(MixMode.allCases.map(\.rawValue) == ["dominance", "sum"])
    }
}

@Suite("GainSmoother")
struct GainSmootherTests {
    @Test func convergesTowardsTheTarget() {
        var s = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 0)
        for _ in 0..<200 { s.step(target: 1, dtSec: 0.01) }
        #expect(abs(s.value - 1) < 1e-4)
    }

    @Test func oneStepFollowsTheOnePoleFormula() {
        var s = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 0)
        let g = s.step(target: 1, dtSec: 0.05)  // dt == tau → 63 %
        #expect(abs(g - (1 - expf(-1))) < 1e-6)
    }

    @Test func attackRisesFasterThanReleaseFalls() {
        var up = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 0)
        var down = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 1)
        let dt: Float = 0.05
        #expect(up.step(target: 1, dtSec: dt) > 1 - down.step(target: 0, dtSec: dt))
    }

    @Test func resetDoesNotSmooth() {
        var s = GainSmoother(initial: 1)
        s.reset(to: 0)
        #expect(s.value == 0)
    }

    @Test func aZeroDtProducesNoNaN() {
        var s = GainSmoother(initial: 0)
        #expect(s.step(target: 1, dtSec: 0) == 1)
    }
}
