// Micara — état des points de la barre (un point par téléphone).
//
// Logique pure, sans AppKit : la barre ne fait que peindre `dots`. Le but est
// qu'un téléphone corresponde à UN point du début à la fin de la réunion,
// même quand le réseau hoquette — un point qui apparaît et disparaît fait
// croire à un départ.

import Foundation

public enum PhoneDotState: Equatable {
    /// Vert : liaison média vivante.
    case connected
    /// Orange : soit la liaison média est tombée, soit le téléphone est parti
    /// et on lui laisse le temps de revenir (« fantôme »).
    case reconnecting
}

public struct PhoneDot: Equatable, Identifiable {
    public let id: String
    public var state: PhoneDotState

    public init(id: String, state: PhoneDotState) {
        self.id = id
        self.state = state
    }
}

public struct PhoneRoster: Equatable {
    private struct Entry: Equatable {
        var id: String
        var state: PhoneDotState
        /// Instant du départ (`left`) : seuls ces points-là expirent.
        var ghostSinceMs: Double?
    }

    /// Ordre stable = ordre d'arrivée. Un tableau, pas un dictionnaire : les
    /// points ne doivent pas changer de place d'un tick à l'autre.
    private var entries: [Entry] = []
    /// Délai laissé à un téléphone parti pour revenir avant que son point parte.
    public let ghostTTLMs: Double

    public init(ghostTTLMs: Double = 30_000) {
        self.ghostTTLMs = ghostTTLMs
    }

    public var dots: [PhoneDot] {
        entries.map { PhoneDot(id: $0.id, state: $0.state) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Nouveau téléphone annoncé par le serveur.
    ///
    /// Un téléphone qui se reconnecte reçoit un phoneId NEUF (le serveur en
    /// tire un à chaque WebSocket). S'il reste un fantôme, on suppose donc que
    /// c'est le même appareil qui revient et on reprend sa place : sinon la
    /// barre montrerait deux points pour un seul téléphone. On retire le
    /// fantôme le plus ancien — c'est celui qui a le plus attendu.
    public mutating func joined(id: String, nowMs: Double) {
        prune(nowMs: nowMs)
        if let existing = entries.firstIndex(where: { $0.id == id }) {
            entries[existing].state = .connected
            entries[existing].ghostSinceMs = nil
            return
        }
        if let oldestGhost = entries
            .enumerated()
            .filter({ $0.element.ghostSinceMs != nil })
            .min(by: { $0.element.ghostSinceMs! < $1.element.ghostSinceMs! })?
            .offset {
            // On réutilise la position du fantôme : le point ne saute pas en
            // bout de barre pendant une simple reconnexion.
            entries[oldestGhost] = Entry(id: id, state: .connected, ghostSinceMs: nil)
            return
        }
        entries.append(Entry(id: id, state: .connected, ghostSinceMs: nil))
    }

    /// La liaison WebRTC est tombée (ICE disconnected) mais le téléphone est
    /// toujours là : même id, point orange, aucune expiration.
    public mutating func mediaLost(id: String, nowMs: Double) {
        prune(nowMs: nowMs)
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .reconnecting
        entries[i].ghostSinceMs = nil
    }

    public mutating func mediaRestored(id: String, nowMs: Double) {
        prune(nowMs: nowMs)
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .connected
        entries[i].ghostSinceMs = nil
    }

    /// Le téléphone a quitté (`phone-left`). Son point devient un fantôme
    /// orange : un passage de tunnel ou un verrouillage d'écran coupe le
    /// WebSocket, l'appareil revient dans la foulée sous un nouvel id.
    public mutating func left(id: String, nowMs: Double) {
        prune(nowMs: nowMs)
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .reconnecting
        entries[i].ghostSinceMs = nowMs
    }

    /// Retire les fantômes périmés. À appeler périodiquement : sans nouvel
    /// événement, rien d'autre ne fait disparaître un point.
    public mutating func prune(nowMs: Double) {
        entries.removeAll { entry in
            guard let since = entry.ghostSinceMs else { return false }
            return nowMs - since >= ghostTTLMs
        }
    }
}
