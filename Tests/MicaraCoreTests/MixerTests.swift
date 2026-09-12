// Reprise des vérifications de `bridge/test-mixer.mjs` : le portage Swift doit
// donner exactement les mêmes décisions que le module JS en production.
//
// swift-testing et non XCTest : cette machine n'a que les Command Line Tools,
// qui ne livrent pas XCTest.framework (seulement Testing.framework).

import Foundation
import Testing
@testable import MicaraCore

@Suite("rmsDb")
struct RmsDbTests {
    @Test func silenceNumeriqueDonnePlancher() {
        #expect(rmsDb([Float](repeating: 0, count: 1024)) == dbFloor)
    }

    @Test func sinusPleineEchelleDonneEnvironMoins3dB() {
        let n = 1024
        let sine = (0..<n).map { Float(sin(Double($0) / Double(n) * 2 * Double.pi)) }
        #expect(rmsDb(sine).rounded() == -3)
    }

    @Test func bufferVideDonnePlancher() {
        #expect(rmsDb([Float]()) == dbFloor)
    }

    @Test func gainDepuisDb() {
        #expect(abs(gainFromDb(0) - 1) < 1e-6)
        #expect(abs(gainFromDb(-6) - 0.5011872) < 1e-6)
        #expect(abs(gainFromDb(-18) - 0.12589254) < 1e-6)
    }
}

@Suite("Gate")
struct GateTests {
    @Test func hysteresisEtHold() {
        let m = DominanceMixer(config: MixerConfig(gateOpenDb: -45, gateCloseDb: -50, gateHoldMs: 400))

        var r = m.tick([LevelEntry(id: "a", db: -60)], nowMs: 0)
        #expect(r.gains["a"] == 0)      // sous le seuil d'ouverture
        #expect(r.openCount == 0)

        r = m.tick([LevelEntry(id: "a", db: -44)], nowMs: 100)
        #expect(r.gains["a"] == 1)      // parole (-44 ≥ -45) → ouvert
        #expect(r.openCount == 1)

        r = m.tick([LevelEntry(id: "a", db: -48)], nowMs: 200)
        #expect(r.gains["a"] == 1)      // hystérésis : -48 ≥ -50 → reste ouvert

        r = m.tick([LevelEntry(id: "a", db: -60)], nowMs: 250)
        #expect(r.gains["a"] == 1)      // hold 400 ms non écoulé

        r = m.tick([LevelEntry(id: "a", db: -60)], nowMs: 700)
        #expect(r.gains["a"] == 0)      // hold écoulé → ferme
    }
}

@Suite("Dominance")
struct DominanceTests {
    @Test func dominanceDuckingMargeDwellEtForget() throws {
        let d = DominanceMixer(config: MixerConfig(duckDb: -18))

        var r = d.tick([LevelEntry(id: "a", db: -30), LevelEntry(id: "b", db: -35)], nowMs: 0)
        #expect(r.gains["a"] == 1)                                  // le plus fort parle
        #expect((20 * log10(try #require(r.gains["b"]))).rounded() == -18) // l'autre est duqué
        #expect(r.dominant == "a")

        r = d.tick([LevelEntry(id: "a", db: -41), LevelEntry(id: "b", db: -40)], nowMs: 50)
        #expect(r.dominant == "a")  // b dépasse de < 3 dB → pas de bascule

        r = d.tick([LevelEntry(id: "a", db: -60), LevelEntry(id: "b", db: -35)], nowMs: 100)
        #expect(r.dominant == "a")  // marge atteinte, dwell 300 ms non écoulé

        r = d.tick([LevelEntry(id: "a", db: -60), LevelEntry(id: "b", db: -35)], nowMs: 450)
        #expect(r.dominant == "b")  // dwell écoulé + marge → bascule

        r = d.tick([LevelEntry(id: "a", db: -80), LevelEntry(id: "b", db: -80)], nowMs: 900)
        #expect(r.gains["a"] == 0)
        #expect(r.gains["b"] == 0)
        #expect(r.dominant == nil)

        d.forget(id: "b")
        r = d.tick([LevelEntry(id: "a", db: -30)], nowMs: 1000)
        #expect(r.gains["b"] == nil)   // flux oublié absent des gains
        #expect(r.dominant == "a")     // le dominant parti → le plus fort reprend
    }

    @Test func forgetDuDominantLibereLaPlaceSansAttendreLeDwell() {
        let d = DominanceMixer()
        _ = d.tick([LevelEntry(id: "a", db: -30), LevelEntry(id: "b", db: -32)], nowMs: 0)
        #expect(d.dominantId == "a")
        d.forget(id: "a")
        // b n'a ni la marge ni le dwell : il prend la main parce que la place
        // est vide — comportement du JS après `removeChannel`.
        #expect(d.tick([LevelEntry(id: "b", db: -32)], nowMs: 50).dominant == "b")
    }

    @Test func modeSommeEstUnEnumStableCarIlEstPersisteDansLesReglages() {
        #expect(MixMode(rawValue: "sum") == .sum)
        #expect(MixMode.allCases.map(\.rawValue) == ["dominance", "sum"])
    }
}

@Suite("GainSmoother")
struct GainSmootherTests {
    @Test func convergeVersLaCible() {
        var s = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 0)
        for _ in 0..<200 { s.step(target: 1, dtSec: 0.01) }
        #expect(abs(s.value - 1) < 1e-4)
    }

    @Test func unPasSuitLaFormuleOnePole() {
        var s = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 0)
        let g = s.step(target: 1, dtSec: 0.05)  // dt == tau → 63 %
        #expect(abs(g - (1 - expf(-1))) < 1e-6)
    }

    @Test func attaqueMonteVitePlusQueLeReleaseNeDescend() {
        var up = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 0)
        var down = GainSmoother(attackSec: 0.05, releaseSec: 0.3, initial: 1)
        let dt: Float = 0.05
        #expect(up.step(target: 1, dtSec: dt) > 1 - down.step(target: 0, dtSec: dt))
    }

    @Test func resetNeLissePas() {
        var s = GainSmoother(initial: 1)
        s.reset(to: 0)
        #expect(s.value == 0)
    }

    @Test func dtNulNeProduitPasDeNaN() {
        var s = GainSmoother(initial: 0)
        #expect(s.step(target: 1, dtSec: 0) == 1)
    }
}
