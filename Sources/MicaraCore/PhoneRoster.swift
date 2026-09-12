// Micara — state of the bar's dots (one dot per phone).
//
// Pure logic, no AppKit: the bar only paints `dots`. The goal is that one phone
// maps to ONE dot from the start of the meeting to its end, even when the
// network hiccups — a dot that appears and vanishes reads as someone leaving.

import Foundation

public enum PhoneDotState: Equatable {
    /// Green: the media link is alive.
    case connected
    /// Orange: either the media link dropped, or the phone left and we are
    /// giving it time to come back (a "ghost").
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
        /// Moment of departure (`left`): only these dots ever expire.
        var ghostSinceMs: Double?
    }

    /// Stable order = arrival order. An array, not a dictionary: the dots must
    /// not swap places from one tick to the next.
    private var entries: [Entry] = []
    /// Grace given to a departed phone to come back before its dot goes away.
    public let ghostTTLMs: Double

    public init(ghostTTLMs: Double = 30_000) {
        self.ghostTTLMs = ghostTTLMs
    }

    public var dots: [PhoneDot] {
        entries.map { PhoneDot(id: $0.id, state: $0.state) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// New phone announced by the server.
    ///
    /// A reconnecting phone gets a BRAND-NEW phoneId (the server draws one per
    /// WebSocket). So if a ghost remains, we assume it is the same device
    /// coming back and reuse its slot: otherwise the bar would show two dots
    /// for a single phone. We take the oldest ghost — it has waited longest.
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
            // Reuse the ghost's position: the dot must not jump to the end of
            // the bar over a mere reconnection.
            entries[oldestGhost] = Entry(id: id, state: .connected, ghostSinceMs: nil)
            return
        }
        entries.append(Entry(id: id, state: .connected, ghostSinceMs: nil))
    }

    /// The WebRTC link dropped (ICE disconnected) but the phone is still here:
    /// same id, orange dot, no expiry.
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

    /// The phone left (`phone-left`). Its dot becomes an orange ghost: a tunnel
    /// or a screen lock cuts the WebSocket, and the device comes straight back
    /// under a new id.
    public mutating func left(id: String, nowMs: Double) {
        prune(nowMs: nowMs)
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].state = .reconnecting
        entries[i].ghostSinceMs = nowMs
    }

    /// Drops expired ghosts. Call it periodically: with no new event, nothing
    /// else makes a dot disappear.
    public mutating func prune(nowMs: Double) {
        entries.removeAll { entry in
            guard let since = entry.ghostSinceMs else { return false }
            return nowMs - since >= ghostTTLMs
        }
    }
}
