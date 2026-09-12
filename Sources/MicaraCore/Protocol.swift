// Micara — messages WebSocket entre le bridge et le serveur de signal.
//
// Formes JSON reprises telles quelles de `server/signal.js` (branche
// `role === 'bridge'`) et de `bridge/renderer/src/engine.js`. Le serveur n'a
// pas changé pour cette réécriture Swift : toute divergence de nom de champ
// casse la négociation WebRTC en silence (le téléphone reste « en attente du
// bridge »), d'où le portage littéral et les tests sur JSON réels.

import Foundation

// MARK: - Types partagés

/// Serveur ICE/TURN reçu dans le `welcome` (credentials Cloudflare, TTL 1 h).
public struct IceServer: Codable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    private enum CodingKeys: String, CodingKey { case urls, username, credential }

    // `urls` arrive en chaîne OU en tableau selon la source (l'API Cloudflare
    // renvoie les deux formes, `server/turn.js` ne normalise que la sienne).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let one = try? c.decode(String.self, forKey: .urls) {
            urls = [one]
        } else {
            urls = try c.decode([String].self, forKey: .urls)
        }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(urls, forKey: .urls)
        try c.encodeIfPresent(username, forKey: .username)
        try c.encodeIfPresent(credential, forKey: .credential)
    }
}

/// `{ type, sdp }` — la forme sérialisée d'un RTCSessionDescription
/// (`serializeAnswer` côté renderer).
public struct SessionDescription: Codable, Equatable {
    public let type: String
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }

    private enum CodingKeys: String, CodingKey { case type, sdp }

    // Tolérance historique : `signal.js` journalise `msg.sdp && msg.sdp.sdp ||
    // msg.sdp`, donc une chaîne nue a déjà circulé. On l'accepte plutôt que
    // d'échouer, en supposant une offre (le bridge ne reçoit que des offres).
    public init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            type = "offer"
            sdp = raw
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        sdp = try c.decode(String.self, forKey: .sdp)
    }
}

/// `{ candidate, sdpMid, sdpMLineIndex }` — `serializeCandidate` côté renderer.
public struct IceCandidate: Codable, Equatable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32?

    public init(candidate: String, sdpMid: String? = nil, sdpMLineIndex: Int32? = nil) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

// MARK: - Serveur → bridge

public enum IncomingMessage: Equatable {
    case welcome(secretCode: String?, iceServers: [IceServer])
    case phoneJoined(phoneId: String)
    case phoneLeft(phoneId: String)
    case offer(phoneId: String, sdp: SessionDescription)
    case ice(phoneId: String, candidate: IceCandidate)
    /// Type non reconnu : le serveur peut en ajouter, le bridge doit survivre.
    case unknown(type: String)

    private struct Envelope: Decodable {
        struct Space: Decodable { let secretCode: String? }
        let type: String
        let space: Space?
        let iceServers: [IceServer]?
        let phoneId: String?
        let sdp: SessionDescription?
        let candidate: IceCandidate?
    }

    /// Décode par le champ `type`. Un message inconnu ou incomplet ne doit
    /// jamais faire tomber la connexion : il devient `.unknown`.
    public static func decode(_ data: Data) throws -> IncomingMessage {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        switch env.type {
        case "welcome":
            return .welcome(secretCode: env.space?.secretCode, iceServers: env.iceServers ?? [])
        case "phone-joined":
            guard let id = env.phoneId else { return .unknown(type: env.type) }
            return .phoneJoined(phoneId: id)
        case "phone-left":
            guard let id = env.phoneId else { return .unknown(type: env.type) }
            return .phoneLeft(phoneId: id)
        case "offer":
            guard let id = env.phoneId, let sdp = env.sdp else { return .unknown(type: env.type) }
            return .offer(phoneId: id, sdp: sdp)
        case "ice":
            guard let id = env.phoneId, let c = env.candidate else { return .unknown(type: env.type) }
            return .ice(phoneId: id, candidate: c)
        default:
            return .unknown(type: env.type)
        }
    }
}

// MARK: - Bridge → serveur

public enum OutgoingMessage: Equatable {
    case answer(phoneId: String, sdp: SessionDescription)
    case ice(phoneId: String, candidate: IceCandidate)
    /// État du FLUX d'un téléphone tel que le bridge le vit — distinct de sa
    /// présence WebSocket : une liaison WebRTC peut mourir sans que le
    /// téléphone parte. Le serveur s'en sert pour ses journaux.
    case streamState(phoneId: String, live: Bool)

    private struct Payload: Encodable {
        let type: String
        let phoneId: String
        var sdp: SessionDescription?
        var candidate: IceCandidate?
        var live: Bool?
    }

    public func encode() throws -> Data {
        let payload: Payload
        switch self {
        case let .answer(phoneId, sdp):
            payload = Payload(type: "answer", phoneId: phoneId, sdp: sdp)
        case let .ice(phoneId, candidate):
            payload = Payload(type: "ice", phoneId: phoneId, candidate: candidate)
        case let .streamState(phoneId, live):
            payload = Payload(type: "stream-state", phoneId: phoneId, live: live)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}

// MARK: - Codes de fermeture WebSocket

/// Table du README racine. Le bridge les affiche à l'utilisateur : un code non
/// traduit devient un « déconnecté » muet, qu'on ne sait pas diagnostiquer.
public enum CloseCode {
    public static let missingParam = 4000
    public static let invalidToken = 4001
    public static let spaceNotFound = 4002
    public static let bridgeAlreadyConnected = 4003
    public static let invalidCode = 4004
    public static let spaceDisabled = 4005
    public static let accountDisabled = 4006
    public static let adminDisconnect = 4007
    public static let spaceFull = 4008
    /// Hors table du README mais émis par `signal.js` vers le bridge.
    public static let meetingEnded = 4010

    public static func describe(_ code: Int) -> String? {
        switch code {
        case missingParam: return "paramètre manquant"
        case invalidToken: return "jeton invalide"
        case spaceNotFound: return "espace introuvable"
        case bridgeAlreadyConnected: return "un autre bridge est déjà connecté"
        case invalidCode: return "code invalide"
        case spaceDisabled: return "espace désactivé"
        case accountDisabled: return "compte désactivé"
        case adminDisconnect: return "déconnexion admin"
        case spaceFull: return "espace plein"
        case meetingEnded: return "réunion terminée"
        default: return nil
        }
    }
}
