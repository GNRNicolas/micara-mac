// Micara — mixage audio : dominance + noise gate.
//
// Portage 1:1 de `bridge/renderer/mixer.cjs` (module pur du bridge Electron).
// Pur : aucune dépendance AppKit / AVFoundation / WebRTC, pour rester testable
// sans matériel audio ni serveur.

import Foundation

/// Plancher dBFS (silence numérique). Aligné sur `DB_MIN` du module JS.
public let dbFloor: Float = -120

/// Gain linéaire correspondant à une valeur en dB (10^(dB/20)).
public func gainFromDb(_ db: Float) -> Float {
    powf(10, db / 20)
}

/// RMS d'un buffer d'échantillons → dBFS, clampé à `dbFloor`.
///
/// Le seuil 1e-9 évite un `log10(0)` = -inf sur un buffer strictement muet :
/// le reste du moteur compare des Float, un -inf contaminerait les moyennes.
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

/// Mode de mixage, exposé au menu de la barre de menus.
/// « Dominance + gate » = le mixeur ci-dessous ; « Somme » = gains à 1,
/// seul le limiteur de sortie protège de l'écrêtage.
public enum MixMode: String, CaseIterable, Codable {
    case dominance
    case sum
}

/// Constantes de mixage — valeurs par défaut = `MIX` de `renderer/src/engine.js`,
/// réglées en réunion réelle (voir les commentaires du JS).
public struct MixerConfig: Equatable {
    /// dBFS : ouverture du gate (parole).
    public var gateOpenDb: Float
    /// dBFS : fermeture du gate, plus bas que l'ouverture (hystérésis anti-clapot).
    public var gateCloseDb: Float
    /// Maintien avant fermeture : sans lui, les fins de mots sont coupées.
    public var gateHoldMs: Double
    /// Atténuation des flux ouverts mais non dominants.
    public var duckDb: Float
    /// Le challenger doit dépasser le dominant d'au moins autant pour prendre la main.
    public var dominanceMarginDb: Float
    /// Délai minimum entre deux bascules de dominant.
    public var dominanceDwellMs: Double
    /// Montée du gain vers la cible (nouveau dominant).
    public var attackSec: Float
    /// Descente du gain vers la cible (gate qui ferme, ancien dominant).
    public var releaseSec: Float
    /// Période de calcul des niveaux.
    public var tickMs: Double
    /// Gain appliqué AVANT la mesure de niveau : un téléphone posé à 1-2 m mesure
    /// -66/-75 dBFS, le gate -45 ne s'ouvrait jamais. +10 dB et pas plus : +18 dB
    /// saturait le limiteur (« voix déformée » — retours réels 19/08).
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

/// Niveau mesuré d'un flux sur un tick. `id` est opaque (phoneId, ou l'id du
/// micro local, que le mixeur traite comme n'importe quel autre flux).
public struct LevelEntry: Equatable {
    public let id: String
    public let db: Float
    public init(id: String, db: Float) {
        self.id = id
        self.db = db
    }
}

/// Résultat d'un tick : gains CIBLES (0…1). Le moteur audio les lisse
/// (`GainSmoother`) — appliquer ces valeurs brutes produirait des clics.
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

/// Mixeur dominance + noise gate.
///
/// Un seul flux « parle » à gain 1 ; les autres flux ouverts sont atténués de
/// `duckDb`, les flux fermés sont à 0. L'anti-clapot (marge + dwell) existe
/// parce que sans lui deux locuteurs de niveaux proches font basculer le
/// dominant à chaque tick (50 ms) : comme l'attaque (50 ms) ≈ la période de
/// tick et que le release est lent (300 ms), les deux gains restent à
/// mi-course et les deux micros restent audibles (constaté le 18/08).
public final class DominanceMixer {
    private struct GateState {
        var open = false
        /// Dernier instant où le flux était au-dessus du seuil de fermeture.
        var lastOpenMs: Double = 0
    }

    public let config: MixerConfig
    private var states: [String: GateState] = [:]
    /// Dominant actuel, persistant entre les ticks (c'est lui que le dwell protège).
    public private(set) var dominantId: String?
    private var lastSwitchMs: Double = 0

    public init(config: MixerConfig = .default) {
        self.config = config
    }

    /// Calcule les gains cibles pour ce tick. `nowMs` est l'horloge du moteur.
    public func tick(_ entries: [LevelEntry], nowMs: Double) -> TickResult {
        // 1) gate par flux : hystérésis + hold
        for e in entries {
            var st = states[e.id] ?? GateState()
            if !st.open {
                if e.db >= config.gateOpenDb {
                    st.open = true
                    st.lastOpenMs = nowMs
                }
            } else if e.db >= config.gateCloseDb {
                st.lastOpenMs = nowMs // au-dessus du seuil bas → on reste ouvert
            } else if nowMs - st.lastOpenMs >= config.gateHoldMs {
                st.open = false
            }
            states[e.id] = st
        }

        // 2) dominance parmi les flux ouverts, avec anti-clapot.
        let open = entries.filter { states[$0.id]?.open == true }
        let openCount = open.count
        var dominant: String?
        if let first = open.first {
            var loudest = first
            for e in open where e.db > loudest.db { loudest = e }
            let cur = dominantId
            // Le dominant sortant ne compte que s'il est encore là ET ouvert :
            // sinon la place est libre et le plus fort la prend sans attendre.
            let curEntry = cur.flatMap { c in open.first { $0.id == c } }
            if let curEntry, let cur {
                if loudest.id == cur {
                    dominant = cur
                } else if nowMs - lastSwitchMs >= config.dominanceDwellMs
                    && loudest.db >= curEntry.db + config.dominanceMarginDb {
                    dominant = loudest.id // nettement plus fort ET délai écoulé
                } else {
                    dominant = cur // trop proche ou trop tôt → on garde
                }
            } else {
                dominant = loudest.id
            }
        }
        if dominant != dominantId {
            dominantId = dominant
            lastSwitchMs = nowMs
        }

        // 3) gains cibles
        let duckGain = gainFromDb(config.duckDb)
        var gains: [String: Float] = [:]
        gains.reserveCapacity(entries.count)
        for e in entries {
            let isOpen = states[e.id]?.open == true
            gains[e.id] = isOpen ? (e.id == dominant ? 1 : duckGain) : 0
        }
        return TickResult(gains: gains, dominant: dominant, openCount: openCount)
    }

    /// Oublie un flux (téléphone déconnecté) — évite les états orphelins.
    /// Si c'était le dominant, le plus fort reprend la main au prochain tick.
    public func forget(id: String) {
        states.removeValue(forKey: id)
        if dominantId == id { dominantId = nil }
    }
}

/// Lissage exponentiel one-pole d'un gain vers sa cible.
///
/// Remplace `setTargetAtTime` de la Web Audio API, qu'AVAudioEngine n'a pas :
/// appliquer les gains cibles du mixeur tels quels produirait un clic à chaque
/// bascule. À chaque pas de `dt` secondes :
///
///     g += (target - g) * (1 - exp(-dt / tau))
///
/// `tau` vaut `attackSec` quand la cible monte, `releaseSec` quand elle
/// descend : la parole doit s'ouvrir vite (50 ms) mais se refermer lentement
/// (300 ms), sinon les fins de mots s'entendent hachées.
public struct GainSmoother {
    public var attackSec: Float
    public var releaseSec: Float
    /// Gain courant (état du lissage).
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
        // tau ou dt nuls : pas de lissage possible → saut direct (évite un NaN).
        guard tau > 0, dtSec > 0 else {
            value = target
            return value
        }
        value += (target - value) * (1 - expf(-dtSec / tau))
        return value
    }

    /// Force le gain sans lissage (branchement d'un flux, arrêt de réunion).
    public mutating func reset(to newValue: Float) {
        value = newValue
    }
}
