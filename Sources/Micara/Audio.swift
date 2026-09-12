// Audio.swift — le moteur temps réel : pistes WebRTC + micro du Mac → mix → BlackHole.
//
// Portage de `bridge/renderer/src/engine.js` (graphe Web Audio) en AVAudioEngine.
// Chaîne : piste distante → LKRTCAudioRenderer → conversion 48 kHz mono →
// ring buffer → AVAudioSourceNode unique (gate/dominance + lissage + limiteur)
// → canaux 1-2 de BlackHole 16ch. Le micro du Mac est un canal comme un autre
// (id `__local__`), jamais coupé par `phonesMuted`, exactement comme LOCAL_ID
// dans le JS.
//
// ─────────────────────────────────────────────────────────────────────────────
// COUPER LE PLAYOUT WEBRTC — RÉSULTAT DU SPIKE (12/09, mesuré sur cette machine)
// ─────────────────────────────────────────────────────────────────────────────
// Question : les pistes distantes doivent arriver dans NOTRE mixeur via le
// renderer, et WebRTC ne doit PAS les jouer lui-même dans les haut-parleurs.
// Les trois options de la spec ont été essayées dans l'ordre, en bouclage local
// (deux LKRTCPeerConnection dans le même process) :
//
//  1. NE PAS démarrer le playout de l'ADM (`stopPlayout` + `setEngineAvailability`
//     avec `isOutputAvailable = false`) → LE RENDERER NE REÇOIT PLUS RIEN.
//     Mesuré : 400 buffers reçus en 4 s avec le playout, 0 sans. Cohérent avec
//     libwebrtc, où le sink d'une piste DISTANTE est alimenté depuis
//     `ChannelReceive::GetAudioFrameWithInfo`, appelé par la seule boucle de
//     playout (AudioMixer tiré par l'ADM). Pas de playout = pas de décodage =
//     pas de PCM. OPTION ÉCARTÉE.
//
//  2. `track.source.volume = 0` → OPTION RETENUE. Mesuré :
//       • le renderer continue de recevoir 100 buffers/s, à pleine amplitude
//         (crête 0,13 avec volume 0 contre 0,12 avec volume 1) ;
//       • ce que l'ADM joue est un SILENCE NUMÉRIQUE : playout redirigé vers
//         BlackHole 2ch et enregistré de l'extérieur → -42,2 dB crête à
//         volume 1, -91 dB (plancher de mesure) à volume 0.
//     Autrement dit le gain de sortie est appliqué APRÈS la livraison au sink :
//     on garde le PCM intact et rien ne sort des haut-parleurs.
//
//  3. `trySetOutputDevice(BlackHole)` : pas nécessaire, et pas disponible non
//     plus — l'ADM `.audioEngine` de ce fork n'expose QUE la sortie par défaut
//     du système dans `outputDevices` (BlackHole n'y figure jamais). Ç'aurait de
//     toute façon été mauvais : notre AVAudioEngine écrit déjà les téléphones
//     dans BlackHole, WebRTC les y aurait écrits une seconde fois.
//
// La factory est créée avec l'ADM `.audioEngine` et `bypassVoiceProcessing = true`
// (voir `SignalClient`) : le traitement de voix de WebRTC ne sert à rien ici —
// le bridge n'ÉMET aucune piste, il ne fait que recevoir.
//
// ─────────────────────────────────────────────────────────────────────────────
// DEUX AVAudioEngine, ET L'ENTRÉE DÉMARRE EN PREMIER
// ─────────────────────────────────────────────────────────────────────────────
// Un AVAudioEngine ne pilote qu'UNE unité d'E/S : fixer
// `kAudioOutputUnitProperty_CurrentDevice` pour sortir sur BlackHole fixerait
// aussi son entrée sur BlackHole — le « micro » du Mac deviendrait notre propre
// mix (boucle). D'où deux moteurs : `outputEngine` (source → BlackHole) et
// `inputEngine` (micro → tap).
//
// ORDRE : l'ENTRÉE d'abord. Monter le moteur d'entrée reconfigure les unités
// d'E/S et TUE un moteur de sortie déjà démarré — mesuré : la sortie rendait
// 36 blocs (~0,4 s) puis se taisait définitivement, sans erreur ni notification.
// Entrée puis sortie : 548 blocs en 5 s, vu-mètre à 0,6, BlackHole enregistré à
// -34 dB crête.
//
// Le micro capté n'est JAMAIS « le device d'entrée par défaut » pris aveuglément :
// pendant une réunion le défaut EST l'agrégat Micara (donc BlackHole). On choisit
// explicitement un vrai micro (`resolveInputDevice`) — au prix de l'AEC quand ce
// micro n'est pas le défaut du système, voir `startInput`.

import AVFoundation
import CoreAudio
import Foundation
import LiveKitWebRTC
import MicaraCore

// MARK: - Constantes

/// Identifiant du micro du Mac dans le mixeur — même valeur que `LOCAL_ID` du JS
/// (le mixeur le traite comme n'importe quel flux : il peut être dominant).
let localChannelID = "__local__"

/// Tout le mixage se fait à 48 kHz mono : c'est le débit de sortie de WebRTC et
/// celui de BlackHole. Un seul taux dans le graphe = une seule conversion, à
/// l'entrée de chaque canal.
private let mixSampleRate: Double = 48_000

/// Limiteur de sortie : mêmes constantes que le `DynamicsCompressor` du JS
/// (`mixComp`), réglées en réunion réelle. Sans lui, le gain d'entrée +10 dB et
/// une parole proche écrêtent à la conversion finale (« voix déformée », 19/08).
private let limiterThresholdDb: Float = -6
private let limiterKneeDb: Float = 6
private let limiterRatio: Float = 20
private let limiterAttackSec: Float = 0.002
private let limiterReleaseSec: Float = 0.15

/// Plafond de retard toléré dans un ring buffer avant de jeter les échantillons
/// les plus vieux. POURQUOI : l'horloge de WebRTC et celle de BlackHole ne sont
/// pas la même ; sans purge, la dérive s'accumule en latence permanente.
private let maxRingLatencySec: Double = 0.20

/// Fenêtre du vu-mètre et du tick de mixage (`MIX.tickMs` du JS).
private let tickSec: Double = 0.05

// MARK: - Ring buffer par canal

/// File circulaire mono Float32, un producteur (le thread WebRTC ou le tap du
/// micro) et un consommateur (le thread CoreAudio).
///
/// POURQUOI un `os_unfair_lock` et pas du lock-free : la section critique est un
/// `memcpy` de quelques centaines de flottants, jamais une allocation ni un
/// appel système. C'est l'option honnête — un lock-free écrit à la main sans
/// primitives atomiques Swift 5.9 aurait été faux plus souvent que lent.
private final class Ring {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var filled = 0
    private var lock = os_unfair_lock_s()
    /// Crête écrite depuis la dernière lecture — diagnostic seulement (le
    /// journal doit pouvoir dire « des paquets arrivent mais ils sont muets »,
    /// panne qu'un compteur de buffers ne distingue pas d'un flux normal).
    private var peakSinceRead: Float = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    func write(_ source: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        // Un buffer plus gros que le ring ne peut pas arriver (10 ms WebRTC vs
        // 500 ms de ring), mais on ne lit que la queue plutôt que déborder.
        let n = min(count, capacity)
        let src = source + (count - n)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<n { peakSinceRead = max(peakSinceRead, abs(src[i])) }
        let firstChunk = min(n, capacity - writeIndex)
        storage.advanced(by: writeIndex).update(from: src, count: firstChunk)
        if firstChunk < n {
            storage.update(from: src + firstChunk, count: n - firstChunk)
        }
        writeIndex = (writeIndex + n) % capacity
        filled = min(filled + n, capacity)
    }

    /// Lit `count` échantillons ; complète par des zéros si le producteur est en
    /// retard (sous-alimentation = silence, jamais du bruit ou du vieux son).
    func read(into destination: UnsafeMutablePointer<Float>, count: Int, dropOlderThan maxFrames: Int) {
        os_unfair_lock_lock(&lock)
        // Purge de la dérive : on jette le plus VIEUX, jamais le plus récent —
        // le retard doit se rattraper en avant, pas en répétant du passé.
        if filled > maxFrames { filled = maxFrames }
        let available = min(filled, count)
        let missing = count - available
        if missing > 0 { destination.update(repeating: 0, count: missing) }
        if available > 0 {
            let start = ((writeIndex - available) % capacity + capacity) % capacity
            let firstChunk = min(available, capacity - start)
            (destination + missing).update(from: storage + start, count: firstChunk)
            if firstChunk < available {
                (destination + missing + firstChunk).update(from: storage, count: available - firstChunk)
            }
            filled -= available
        }
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        filled = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Crête écrite depuis le dernier appel, puis remise à zéro.
    func drainPeak() -> Float {
        os_unfair_lock_lock(&lock)
        defer { peakSinceRead = 0; os_unfair_lock_unlock(&lock) }
        return peakSinceRead
    }
}

// MARK: - Canal

/// Un flux dans le mix : le ring alimenté par WebRTC (ou le micro), l'état de
/// lissage (thread audio seul) et la boîte aux lettres partagée avec le tick.
private final class Channel {
    let id: String
    let isLocal: Bool
    let ring = Ring(capacity: Int(mixSampleRate / 2))  // 500 ms

    /// État du thread audio EXCLUSIVEMENT : personne d'autre n'y touche.
    var smoother = GainSmoother()

    // Boîte aux lettres thread audio ↔ tick, sous un verrou tenu quelques
    // nanosecondes (deux Double et un Float).
    private var lock = os_unfair_lock_s()
    private var sumSquares: Double = 0
    private var sampleCount: Int = 0
    private var target: Float = 0

    init(id: String, isLocal: Bool) {
        self.id = id
        self.isLocal = isLocal
    }

    /// Thread audio → tick : niveau mesuré APRÈS le gain d'entrée (comme le JS,
    /// où l'analyseur est branché après `inputGain`).
    func accumulate(sumSquares s: Double, count: Int) {
        os_unfair_lock_lock(&lock)
        sumSquares += s
        sampleCount += count
        os_unfair_lock_unlock(&lock)
    }

    /// Tick → lit et remet à zéro la fenêtre. `nil` si aucun échantillon n'est
    /// passé (canal tout juste créé) : pas de mesure = pas d'entrée de niveau.
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

// MARK: - Renderer d'une piste distante

/// Reçoit le PCM d'une `LKRTCAudioTrack` (thread de WebRTC, pas le thread
/// CoreAudio), le convertit en 48 kHz mono Float32 et le pousse dans le ring.
///
/// La conversion est faite ICI, hors du thread temps réel : c'est le seul
/// endroit où l'on peut allouer sans risquer un glitch de sortie.
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

    /// Compteur de diagnostic (spike + journal) : prouve que le PCM arrive.
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

    /// Ramène n'importe quel format livré par WebRTC (Int16/Float32, 1 ou 2
    /// canaux, 48 kHz en pratique) au format du mix. Le convertisseur est
    /// reconstruit si le format change en cours de route.
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

// MARK: - État du thread audio

/// Tout ce que le bloc de rendu touche. Objet séparé (et non `AudioEngine`) pour
/// que le bloc puisse le capturer fortement sans créer de cycle avec le moteur.
private final class Mixdown {
    var config: MixerConfig
    private var stateLock = os_unfair_lock_s()
    private var pendingChannels: [Channel]?
    /// Copie détenue par le seul thread audio : évite de prendre le verrou quand
    /// rien n'a changé (le cas de 99,99 % des blocs).
    private var renderChannels: [Channel] = []

    private var _mode: MixMode = .dominance
    private var _muted = false
    private var outSumSquares: Double = 0
    private var outSampleCount: Int = 0
    /// Nombre de blocs rendus — diagnostic : zéro = le graphe de sortie ne tourne
    /// pas du tout (device pris par un autre process, format refusé…).
    private(set) var renderCount: Int = 0

    // Tampons préalloués : aucune allocation dans le bloc de rendu.
    private let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private let mix: UnsafeMutablePointer<Float>

    // État du limiteur (thread audio seul).
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

    /// Snapshot pour le tick (hors thread audio).
    func channelsSnapshot() -> [Channel] {
        withLock { pendingChannels ?? renderChannels }
    }

    /// Niveau du mix sur la fenêtre écoulée, en dBFS. `nil` si le moteur n'a pas
    /// rendu un seul bloc depuis le dernier appel (moteur arrêté).
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

    // MARK: bloc de rendu (thread CoreAudio — aucune allocation, aucun verrou long)

    func render(frameCount: Int, output: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        let frames = min(frameCount, maxFrames)
        renderCount += 1

        // Récupération de la nouvelle liste de canaux SANS bloquer : si le tick
        // ou la main queue tient le verrou, on garde la liste précédente un
        // bloc de plus (5-10 ms) plutôt que d'attendre sur le thread audio.
        if os_unfair_lock_trylock(&stateLock) {
            if let pending = pendingChannels {
                renderChannels = pending
                pendingChannels = nil
            }
            os_unfair_lock_unlock(&stateLock)
        }
        let muted = _muted  // lecture non verrouillée d'un Bool : au pire on
        // applique la valeur d'avant pendant un bloc.

        mix.update(repeating: 0, count: frames)
        let inputGain = gainFromDb(config.inputGainDb)
        let maxLatencyFrames = Int(maxRingLatencySec * mixSampleRate)
        let dt = Float(Double(frames) / mixSampleRate)

        for channel in renderChannels {
            channel.ring.read(into: scratch, count: frames, dropOlderThan: maxLatencyFrames)

            // Gain d'entrée AVANT la mesure : c'est l'ordre du JS (source →
            // inputGain → analyser), et c'est ce qui fait que le gate -45 dB
            // s'ouvre pour un téléphone posé à deux mètres.
            var sumSq: Double = 0
            for i in 0..<frames {
                let s = scratch[i] * inputGain
                scratch[i] = s
                sumSq += Double(s) * Double(s)
            }
            channel.accumulate(sumSquares: sumSq, count: frames)

            // Le micro du Mac ne se coupe JAMAIS avec « Couper » : l'admin doit
            // rester entendu dans Teams (règle 6 de la spec).
            let target = (muted && !channel.isLocal) ? 0 : channel.targetGain
            let from = channel.smoother.value
            let to = channel.smoother.step(target: target, dtSec: dt)
            // Rampe linéaire sur le bloc : appliquer le gain lissé en escalier
            // (une valeur par bloc) s'entend comme un clic à chaque bascule.
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

        // BlackHole 16ch : le mix part en stéréo dupliquée sur les canaux 1-2,
        // le reste à zéro. Teams/Zoom ne prennent que les deux premiers canaux
        // de l'agrégat ; y écrire ailleurs serait invisible pour eux.
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

    /// Limiteur soft-knee sur le mix, équivalent du `DynamicsCompressor` du JS
    /// (seuil -6 dBFS, genou 6 dB, ratio 20, attaque 2 ms, release 150 ms).
    /// Le clip final à ±1 est une ceinture : le limiteur laisse passer un
    /// transitoire plus court que son attaque, la conversion en aval, non.
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

// MARK: - Moteur

enum AudioEngineError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case noInputDevice
    case coreAudio(OSStatus, String)

    var description: String {
        switch self {
        case let .deviceNotFound(uid): return "Périphérique de sortie introuvable : « \(uid) »"
        case .noInputDevice: return "Aucun micro utilisable (hors BlackHole / agrégat Micara)"
        case let .coreAudio(status, what): return "\(what) a échoué (OSStatus \(status))"
        }
    }
}

final class AudioEngine {

    // MARK: état public

    var mode: MixMode {
        get { mixdown.mode }
        set { mixdown.mode = newValue }
    }

    /// Gain 0 sur TOUS les téléphones ; le micro du Mac continue (spec, règle 6).
    var phonesMuted: Bool {
        get { mixdown.phonesMuted }
        set { mixdown.phonesMuted = newValue }
    }

    /// Niveau du mix final, 0…1, sur la main queue, ~20 Hz.
    var onLevel: ((Float) -> Void)?

    private(set) var isRunning = false

    // MARK: état interne

    private let config: MixerConfig
    private let mixer: DominanceMixer
    private let mixdown: Mixdown

    /// File série qui possède la table des canaux et le tick. Le thread audio ne
    /// la touche jamais : il lit un snapshot publié par `Mixdown`.
    private let queue = DispatchQueue(label: "com.getmicara.audio.control")
    private var channels: [String: Channel] = [:]
    private var renderers: [String: TrackRenderer] = [:]
    private var tracks: [String: LKRTCAudioTrack] = [:]

    private var outputEngine: AVAudioEngine?
    private var inputEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var tickTimer: DispatchSourceTimer?
    private var inputConverter: AVAudioConverter?
    private var inputConverterFormat: AVAudioFormat?
    /// Tampon mono réutilisé par le tap du micro (pas d'allocation par buffer).
    private var localMono: [Float] = []

    /// Dominant courant (diagnostic / journal), publié par le tick.
    private(set) var dominantID: String?
    /// Micro effectivement capté — `nil` si aucun (permission TCC refusée,
    /// ou seul BlackHole disponible). L'UI doit pouvoir le dire à l'utilisateur.
    private(set) var inputDeviceName: String?
    /// L'AEC est-elle réellement active sur le micro ? Faux quand le micro voulu
    /// n'est pas l'entrée par défaut du système (limitation du VPIO, cf.
    /// `startInput`) — l'UI et le journal doivent pouvoir le dire.
    private(set) var inputEchoCancelled = false

    init(config: MixerConfig = .default) {
        self.config = config
        mixer = DominanceMixer(config: config)
        mixdown = Mixdown(config: config)
    }

    deinit { stop() }

    // MARK: - Démarrage / arrêt

    /// Démarre le graphe : entrée = un vrai micro (AEC activée), sortie = le
    /// device dont l'UID est donné. `inputDeviceUID` sert aux tests ; en
    /// production on laisse `nil` et le moteur choisit (voir `resolveInputDevice`).
    func start(outputDeviceUID: String, inputDeviceUID: String? = nil) throws {
        try queue.sync {
            guard !isRunning else { return }
            // ENTRÉE D'ABORD : monter le moteur d'entrée reconfigure l'unité
            // d'E/S et fait tomber un moteur de sortie déjà démarré (mesuré au
            // spike : la sortie ne rendait plus que ~36 blocs puis se taisait).
            // Un micro absent ou refusé (TCC) ne doit PAS empêcher la réunion :
            // les téléphones sont l'essentiel, le micro du Mac est un bonus.
            do { try startInput(uid: inputDeviceUID) } catch {
                inputEngine = nil
                inputDeviceName = nil
            }
            try startOutput(uid: outputDeviceUID)
            startTick()
            isRunning = true
        }
    }

    func stop() {
        queue.sync {
            guard isRunning || outputEngine != nil || inputEngine != nil else { return }
            tickTimer?.cancel()
            tickTimer = nil

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

    // MARK: - Téléphones

    /// Attache un renderer à la piste distante et crée son canal. Appelé dès que
    /// la piste existe, SANS attendre `ICE connected` : côté Chromium, `ontrack`
    /// précède l'établissement ICE (piège documenté dans `engine.js`) et
    /// attendre ferait rater le début de la parole.
    func addPhone(id: String, track: LKRTCAudioTrack) {
        queue.async { [self] in
            guard channels[id] == nil else { return }
            let channel = Channel(id: id, isLocal: false)
            channel.smoother = GainSmoother(attackSec: config.attackSec, releaseSec: config.releaseSec)
            let renderer = TrackRenderer(channel: channel)
            // Option 2 du spike : le PCM continue d'arriver au renderer, mais
            // WebRTC ne joue plus rien dans les haut-parleurs.
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

    /// Diagnostic (journal, télémétrie) : par canal, le nombre de buffers PCM
    /// reçus depuis l'attache et la crête écrite depuis le dernier appel.
    /// Les deux ensemble distinguent « rien n'arrive » de « ça arrive muet ».
    /// Blocs rendus par le nœud de sortie depuis le démarrage.
    var renderedBlocks: Int { mixdown.renderCount }

    func diagnostics() -> [String: (buffers: Int, peak: Float)] {
        queue.sync {
            var out: [String: (buffers: Int, peak: Float)] = [:]
            for (id, channel) in channels {
                out[id] = (renderers[id]?.bufferCount ?? 0, channel.ring.drainPeak())
            }
            return out
        }
    }

    // MARK: - Graphe de sortie

    private func startOutput(uid: String) throws {
        guard let device = AudioDevices.find(uid: uid) else {
            throw AudioEngineError.deviceNotFound(uid)
        }
        let engine = AVAudioEngine()
        // Fixer le device AVANT de lire le format : c'est le format du device
        // choisi qui doit dicter le nombre de canaux (16 pour BlackHole), pas
        // celui de la sortie par défaut.
        try setDevice(device.id, on: engine.outputNode, what: "sortie")

        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let channelCount = max(hardware.channelCount, 2)
        let sampleRate = hardware.sampleRate > 0 ? hardware.sampleRate : mixSampleRate
        // Au-delà de 2 canaux, AVAudioFormat EXIGE une disposition explicite :
        // l'initialiseur « commonFormat » renvoie nil, et BlackHole en a 16.
        // `DiscreteInOrder` = pas de rôle (gauche/droite/LFE…), les canaux sont
        // numérotés — c'est exactement ce que l'agrégat expose à Teams.
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)
        ) else {
            throw AudioEngineError.coreAudio(-1, "format de sortie \(channelCount) canaux")
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

        outputEngine = engine
        sourceNode = node
    }

    // MARK: - Micro du Mac

    private func startInput(uid: String?) throws {
        guard let device = try resolveInputDevice(uid: uid) else {
            throw AudioEngineError.noInputDevice
        }
        let channel = Channel(id: localChannelID, isLocal: true)
        channel.smoother = GainSmoother(attackSec: config.attackSec, releaseSec: config.releaseSec)

        // AEC (équivalent d'`echoCancellation: true` côté Chromium) : possible
        // SEULEMENT si le micro voulu est déjà l'entrée par défaut du système.
        // Mesuré au spike : `setVoiceProcessingEnabled(true)` remonte le VPIO sur
        // l'ENTRÉE PAR DÉFAUT et écrase le device qu'on venait de forcer (relu
        // après coup : 132 au lieu de 138). Et forcer le device APRÈS l'avoir
        // activé échoue (-10875) à tous les coups. Donc : AEC quand le défaut est
        // le bon micro, capture sans AEC sinon. Ne jamais inverser la priorité —
        // capter BlackHole par erreur boucle le mix sur lui-même.
        let canUseAEC = AudioDevices.defaultInputUID() == device.uid
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

    /// Monte un moteur d'entrée seule sur un device précis.
    ///
    /// ORDRE CRITIQUE, trouvé au spike (toute autre séquence donne un tap qui ne
    /// se déclenche JAMAIS, sans la moindre erreur, ou une unité qui refuse de
    /// s'initialiser) :
    ///   1. `AudioUnitUninitialize` — on ne peut pas changer le device d'une
    ///      unité déjà initialisée : la propriété est ACCEPTÉE (status 0) et le
    ///      tap reste muet pour toujours ;
    ///   2. `kAudioOutputUnitProperty_CurrentDevice` ;
    ///   3. `AudioUnitInitialize` ;
    ///   4. `setVoiceProcessingEnabled` EN DERNIER (l'appeler avant fait échouer
    ///      l'initialisation sur le device forcé) ;
    ///   5. format du tap = `inputFormat(forBus:)`, le format MATÉRIEL. Avec
    ///      `outputFormat` ou `nil`, aucun callback n'arrive.
    ///
    /// Avec le VPIO, le bus d'entrée expose 5 canaux PORTANT LE MÊME SIGNAL
    /// (mesuré : RMS identique au dixième de dB sur les 5) : prendre le canal 0
    /// est correct, et laisser `AVAudioConverter` « mélanger » ces 5 canaux ne
    /// l'est pas (voir `pushLocal`).
    private func makeInputEngine(
        device: AudioDeviceInfo, voiceProcessing: Bool, channel: Channel
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let unit = input.audioUnit else {
            throw AudioEngineError.coreAudio(-1, "unité audio entrée")
        }
        _ = AudioUnitUninitialize(unit)
        var deviceID = device.id
        let set = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard set == noErr else {
            throw AudioEngineError.coreAudio(set, "device d'entrée \(device.name)")
        }
        let initialized = AudioUnitInitialize(unit)
        guard initialized == noErr else {
            throw AudioEngineError.coreAudio(initialized, "AudioUnitInitialize (entrée)")
        }
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        }
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioEngineError.coreAudio(-1, "format d'entrée vide")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.pushLocal(buffer, into: channel)
        }
        engine.prepare()
        try engine.start()
        return engine
    }

    /// Convertit le buffer du micro en 48 kHz mono et le pousse dans le ring.
    /// Le tap ne tourne pas sur le thread CoreAudio de la sortie : allouer le
    /// convertisseur ici est sans conséquence pour le rendu.
    /// POURQUOI ne PAS laisser `AVAudioConverter` faire la réduction de canaux :
    /// avec le VPIO actif, le micro du Mac arrive en 5 canaux sans disposition
    /// standard ; `AVAudioConverter` refuse alors silencieusement la conversion
    /// (aucune erreur remontée, zéro trame produite — le micro restait muet au
    /// spike). On extrait donc le canal 0 nous-mêmes, et le convertisseur ne
    /// fait plus que du rééchantillonnage mono → mono.
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

    /// Choisit le micro. JAMAIS « le device d'entrée par défaut » sans le
    /// vérifier : pendant une réunion, le défaut est l'agrégat Micara, dont
    /// l'entrée est BlackHole — c'est-à-dire NOTRE PROPRE MIX. Se capter
    /// soi-même produirait une boucle qui monte jusqu'au limiteur en secondes.
    private func resolveInputDevice(uid: String?) throws -> AudioDeviceInfo? {
        let devices = AudioDevices.all().filter { $0.inputChannels > 0 }
        if let uid {
            guard let forced = devices.first(where: { $0.uid == uid }) else {
                throw AudioEngineError.deviceNotFound(uid)
            }
            return forced
        }
        let forbidden: (AudioDeviceInfo) -> Bool = { device in
            device.uid == MicaraAggregate.uid
                || device.isAggregate
                || device.name.lowercased().contains("blackhole")
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
            throw AudioEngineError.coreAudio(-1, "unité audio \(what)")
        }
        // Une unité d'E/S déjà initialisée refuse le changement de device : au
        // spike, le 3e `start()` d'affilée échouait avec 'nope'
        // (kAudioHardwareIllegalOperationError) alors que les deux premiers
        // passaient. Désinitialiser d'abord rend l'opération reproductible.
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

    /// POURQUOI un timer et pas le bloc de rendu : `DominanceMixer.tick` alloue
    /// (dictionnaire de gains, tableau des flux ouverts) et le thread CoreAudio
    /// n'a le droit ni d'allouer ni de prendre un verrou long. Le thread audio
    /// publie donc des sommes de carrés par canal ; ce timer les draine toutes
    /// les 50 ms (`MIX.tickMs`), appelle le mixeur, et ne renvoie au thread
    /// audio qu'un Float par canal. Le lissage, lui, reste sur le thread audio,
    /// seul endroit où `dt` est exact.
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
            // « Somme » : tout le monde à 1, seul le limiteur protège (spec).
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
            // Échelle perceptive : -60 dB → 0, 0 dB → 1. En dessous de -60 dB,
            // un vu-mètre linéaire en amplitude ne bouge plus du tout.
            let level = max(0, min(1, (db + 60) / 60))
            DispatchQueue.main.async { onLevel(level) }
        }
    }
}
