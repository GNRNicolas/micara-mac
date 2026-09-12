// Micara — WebSocket messages between the bridge and the signalling server.
//
// JSON shapes lifted verbatim from `server/signal.js` (the `role === 'bridge'`
// branch) and from `bridge/renderer/src/engine.js`. The server did not change
// for this Swift rewrite: any field-name drift breaks WebRTC negotiation
// silently (the phone stays "waiting for the bridge"), hence the literal port
// and the tests over real JSON.

import Foundation

// MARK: - Shared types

/// ICE/TURN server received in the `welcome` (Cloudflare credentials, 1 h TTL).
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

    // `urls` arrives as a string OR an array depending on the source (the
    // Cloudflare API returns both shapes, `server/turn.js` only normalises its
    // own).
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

/// `{ type, sdp }` — the serialised form of an RTCSessionDescription
/// (`serializeAnswer` on the renderer side).
public struct SessionDescription: Codable, Equatable {
    public let type: String
    public let sdp: String

    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }

    private enum CodingKeys: String, CodingKey { case type, sdp }

    // Historical tolerance: `signal.js` logs `msg.sdp && msg.sdp.sdp ||
    // msg.sdp`, so a bare string has already been seen on the wire. We accept
    // it rather than fail, assuming an offer (the bridge only receives offers).
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

/// `{ candidate, sdpMid, sdpMLineIndex }` — `serializeCandidate` on the renderer side.
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

// MARK: - Server → bridge

public enum IncomingMessage: Equatable {
    case welcome(secretCode: String?, iceServers: [IceServer])
    case phoneJoined(phoneId: String)
    case phoneLeft(phoneId: String)
    case offer(phoneId: String, sdp: SessionDescription)
    case ice(phoneId: String, candidate: IceCandidate)
    /// Unrecognised type: the server may add new ones, the bridge must survive.
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

    /// Decodes on the `type` field. An unknown or incomplete message must never
    /// bring the connection down: it becomes `.unknown`.
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

// MARK: - Bridge → server

public enum OutgoingMessage: Equatable {
    case answer(phoneId: String, sdp: SessionDescription)
    case ice(phoneId: String, candidate: IceCandidate)
    /// State of a phone's STREAM as the bridge sees it — distinct from its
    /// WebSocket presence: a WebRTC link can die without the phone leaving. The
    /// server uses it for its logs.
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

// MARK: - WebSocket close codes

/// Table from the root README. The bridge shows these to the user: an
/// untranslated code becomes a mute "disconnected" that nobody can diagnose.
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
    /// Not in the README table, but emitted by `signal.js` towards the bridge.
    public static let meetingEnded = 4010

    public static func describe(_ code: Int) -> String? {
        switch code {
        case missingParam: return "missing parameter"
        case invalidToken: return "invalid token"
        case spaceNotFound: return "space not found"
        case bridgeAlreadyConnected: return "another bridge is already connected"
        case invalidCode: return "invalid code"
        case spaceDisabled: return "space disabled"
        case accountDisabled: return "account disabled"
        case adminDisconnect: return "admin disconnect"
        case spaceFull: return "space full"
        case meetingEnded: return "meeting ended"
        default: return nil
        }
    }
}
