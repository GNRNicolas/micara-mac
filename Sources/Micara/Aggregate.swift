// Aggregate.swift — CoreAudio pur : périphérique agrégé « Micara » + micro par défaut.
//
// Portage fidèle de `../bridge/native/micara-audio.c` (helper C du bridge Electron)
// et remplacement de `SwitchAudioSource` (`../bridge/lib/mic-setup.js`).
//
// POURQUOI UN AGRÉGAT : Teams/Zoom affichent le NOM du device d'entrée. Le driver
// BlackHole s'appelle « BlackHole 16ch », et ce nom est compilé dans le driver :
// le renommer imposerait de forker + recompiler + resigner (compte Apple Developer).
// Un périphérique agrégé CoreAudio qui enveloppe BlackHole 16ch donne le bon nom
// SANS AUCUN privilège : un agrégat vit dans les réglages audio de l'utilisateur
// (AudioHardwareCreateAggregateDevice), là où installer un driver exige root.
//
// POURQUOI PLUS DE BINAIRE C NI DE SwitchAudioSource : en Swift, l'API HAL est
// directement accessible dans le process de l'app. Plus de fork/exec, plus de
// parsing JSON, plus de binaire tiers à embarquer et à faire vivre dans les
// ressources — et surtout : l'erreur CoreAudio remonte telle quelle (OSStatus)
// au lieu d'un code de retour 0/1.
//
// INVARIANT REPRIS DU C : on ne touche JAMAIS un agrégat qu'on n'a pas créé.
// L'identité est l'UID `com.getmicara.bridge.aggregate`, PAS le nom affiché
// (que l'utilisateur peut changer dans Configuration audio et MIDI).

import CoreAudio
import Foundation

// MARK: - Erreurs

enum AudioDeviceError: Error, CustomStringConvertible {
    /// Un appel HAL a échoué. Le `String` nomme l'opération (utile en journal :
    /// un OSStatus seul ne dit pas d'où il vient).
    case osStatus(OSStatus, String)
    case notFound(String)
    case blackHoleMissing

    var description: String {
        switch self {
        case let .osStatus(status, what):
            // Les OSStatus CoreAudio sont souvent des FourCC ('!obj', 'stop'…) :
            // on affiche les deux formes, sinon le code brut est indéchiffrable.
            return "CoreAudio \(what) a échoué (OSStatus \(status)\(Self.fourCC(status)))"
        case let .notFound(uid):
            return "Aucun périphérique audio avec l'UID « \(uid) »"
        case .blackHoleMissing:
            return "BlackHole 16ch n'est pas installé"
        }
    }

    private static func fourCC(_ status: OSStatus) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((UInt32(bitPattern: status) >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return " '\(String(decoding: bytes, as: UTF8.self))'"
    }
}

// MARK: - Description d'un device

struct AudioDeviceInfo: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let isAggregate: Bool
}

// MARK: - Accès HAL

enum AudioDevices {

    // --- primitives de lecture de propriété (équivalents des helpers du C) ---

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

    /// Lit une propriété de type CFString (UID, nom). `nil` si le device ne la
    /// publie pas — c'est courant et jamais fatal, on filtre plus haut.
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

    /// Somme des canaux de tous les buffers du device dans un scope donné —
    /// même calcul que `device_channels()` du C (un device peut exposer
    /// plusieurs buffers, en compter un seul sous-estime les canaux).
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

    // --- API publique ---

    static func all() -> [AudioDeviceInfo] {
        deviceIDs().compactMap { id in
            // Un device sans UID n'est pas adressable de façon stable : on
            // l'ignore plutôt que d'inventer une clé (le C le laissait passer
            // avec une chaîne vide, ce qui polluait la liste).
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

    /// UID du device pointé par une propriété « device par défaut » du système.
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

    /// POURQUOI exposer la sortie par défaut : le moteur audio doit savoir où
    /// NE PAS jouer. Si l'utilisateur a mis BlackHole en sortie système, jouer
    /// sur « le device par défaut » réinjecterait le mix dans lui-même.
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

    /// Jeton d'écoute : tant qu'il est retenu, `handler` est appelé à chaque
    /// changement de la liste des devices. Son `deinit` retire le listener —
    /// c'est le seul moyen sûr de ne pas laisser un bloc pendre dans le HAL.
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

    /// Observe l'arrivée/départ de devices (BlackHole installé, casque branché,
    /// agrégat créé par un autre process…). Callback sur la main queue : les
    /// appelants sont l'UI et le moteur audio, tous deux pilotés depuis le main.
    @discardableResult
    static func observeDeviceList(_ handler: @escaping () -> Void) -> AnyObject {
        var addr = address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        return ListenerToken(address: addr, block: block)
    }
}

// MARK: - Agrégat « Micara »

enum MicaraAggregate {
    static let uid = "com.getmicara.bridge.aggregate"
    static let name = "Micara"
    /// UID du driver officiel BlackHole 16ch (constante du driver, stable
    /// depuis la v0.2). Repli par nom si le driver change un jour d'UID.
    static let blackHoleUID = "BlackHole16ch_UID"

    struct Status: Equatable {
        let present: Bool
        let healthy: Bool
        let blackHolePresent: Bool
        /// UID de l'agrégat quand il existe (à passer à `setDefaultInput`),
        /// `nil` sinon.
        let deviceUID: String?
    }

    /// BlackHole utilisable par Micara : l'UID officiel du 16ch d'abord, sinon
    /// tout device dont le nom contient « blackhole » SANS « 2ch » ni « mirror ».
    /// Invariant du projet (cf. `lib/mic-setup.js`) : le 2ch n'est JAMAIS utilisé.
    fileprivate static func findBlackHole() -> AudioDeviceInfo? {
        let devices = AudioDevices.all()
        if let exact = devices.first(where: { $0.uid == blackHoleUID }) { return exact }
        return devices.first { device in
            // Ne jamais empiler un agrégat : un agrégat qui contient BlackHole
            // porte « blackhole » dans son nom et deviendrait un sous-device
            // récursif.
            guard !device.isAggregate else { return false }
            let n = device.name.lowercased()
            return n.contains("blackhole")
                && !n.contains("2ch") && !n.contains("2 ch") && !n.contains("mirror")
        }
    }

    static var blackHoleInstalled: Bool { findBlackHole() != nil }

    /// L'agrégat contient-il déjà ce sous-device ? ROBUSTESSE : si BlackHole a
    /// été désinstallé puis réinstallé, l'agrégat peut être vide → il
    /// apparaîtrait dans la liste de Teams mais serait MUET, pire que pas
    /// d'agrégat du tout.
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
        // La liste contient des CFString (UID des sous-devices) ; certaines
        // versions de macOS y mettent des dictionnaires décrivant le sous-device.
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
            // IsPrivate=0 : visible par TOUTES les apps (Teams/Zoom) et pas
            // seulement par le process créateur.
            kAudioAggregateDeviceIsPrivateKey: 0,
            // IsStacked=0 : les canaux des sous-devices ne sont pas empilés —
            // avec un seul sous-device, l'agrégat expose les 16 canaux de
            // BlackHole dans l'ordre (1↔1) : indispensable pour que le mix
            // écrit sur les canaux 1-2 ressorte bien sur les canaux 1-2 côté
            // entrée.
            kAudioAggregateDeviceIsStackedKey: 0,
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, "AudioHardwareCreateAggregateDevice")
        }
        return device
    }

    /// Attend que coreaudiod ait publié (ou retiré) l'agrégat dans la liste
    /// globale des devices. POURQUOI : `AudioHardwareCreate/DestroyAggregateDevice`
    /// rend la main dès que coreaudiod a accusé réception, mais la propriété
    /// `kAudioHardwarePropertyDevices` est mise à jour de façon asynchrone —
    /// un `status()` immédiat pouvait renvoyer `present:false` juste après un
    /// `ensure()`. Le helper C ne rencontrait pas le problème : il sortait du
    /// process aussitôt après la création, la publication se faisant après sa
    /// mort. Ici le process survit et interroge : il faut attendre.
    private static func waitForPublication(present expected: Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while (AudioDevices.find(uid: uid) != nil) != expected, Date() < deadline {
            // 25 ms : assez court pour ne pas ralentir « Créer une réunion »,
            // assez long pour ne pas marteler le HAL.
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    /// Idempotent : crée l'agrégat s'il manque, le répare s'il a perdu BlackHole,
    /// ne touche jamais à un agrégat qui n'est pas le nôtre (identité = UID).
    @discardableResult
    static func ensure() throws -> Status {
        guard let blackHole = findBlackHole() else { throw AudioDeviceError.blackHoleMissing }

        if let existing = AudioDevices.find(uid: uid) {
            if hasSubDevice(existing.id, uid: blackHole.uid) {
                return status()  // « kept » du C : rien à faire.
            }
            // Agrégat orphelin (BlackHole réinstallé sous un autre UID, ou
            // agrégat créé avant le driver) : on le détruit et on le refait
            // plutôt que de laisser un device muet dans la liste de Teams.
            let st = AudioHardwareDestroyAggregateDevice(existing.id)
            guard st == noErr else {
                throw AudioDeviceError.osStatus(st, "AudioHardwareDestroyAggregateDevice (réparation)")
            }
            waitForPublication(present: false)
        }

        _ = try createAggregate(blackHoleUID: blackHole.uid)
        waitForPublication(present: true)
        return status()
    }

    /// Détruit UNIQUEMENT l'agrégat portant notre UID. Absent = succès
    /// silencieux (l'opération est idempotente, comme `remove` du C).
    static func remove() throws {
        guard let aggregate = AudioDevices.find(uid: uid) else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregate.id)
        guard status == noErr else {
            throw AudioDeviceError.osStatus(status, "AudioHardwareDestroyAggregateDevice")
        }
        waitForPublication(present: false)
    }
}

// MARK: - Micro par défaut, avec restauration

/// Bascule du micro par défaut du système vers « Micara », et retour.
///
/// Remplace `SwitchAudioSource` (`lib/mic-setup.js`) : plus de binaire tiers
/// embarqué, plus de sélection par NOM (fragile : l'utilisateur peut renommer
/// un device, et deux devices peuvent porter le même nom). Ici l'identité est
/// l'UID de notre agrégat, exactement comme pour sa création.
///
/// L'UID mémorisé est persisté dans UserDefaults : si l'app meurt entre
/// `activate()` et `restore()`, le prochain lancement peut encore rendre à
/// l'utilisateur le micro qu'il avait avant Micara.
final class DefaultInputSwitcher {
    private static let key = "previousInputUID"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Mémorise le micro courant puis force « Micara ».
    /// POURQUOI le garde-fou « sauf si c'est déjà Micara » : un double
    /// `activate()` (réunion relancée sans `restore()`, ou reprise après crash)
    /// écraserait la mémoire avec « Micara » et l'utilisateur ne retrouverait
    /// jamais son micro.
    func activate() throws {
        let current = AudioDevices.defaultInputUID()
        if let current, current != MicaraAggregate.uid {
            defaults.set(current, forKey: Self.key)
        }
        try AudioDevices.setDefaultInput(uid: MicaraAggregate.uid)
    }

    /// Remet l'ancien micro s'il existe encore ; sinon laisse macOS choisir
    /// (le système bascule tout seul quand le device par défaut disparaît —
    /// forcer un autre device à sa place serait plus surprenant que de ne rien
    /// faire). Ne lance jamais : `restore()` est appelé en fin de réunion et
    /// dans les chemins d'erreur, il ne doit pas en créer un nouveau.
    func restore() {
        defer { defaults.removeObject(forKey: Self.key) }
        guard let previous = defaults.string(forKey: Self.key),
              previous != MicaraAggregate.uid,
              AudioDevices.find(uid: previous) != nil else { return }
        try? AudioDevices.setDefaultInput(uid: previous)
    }
}
