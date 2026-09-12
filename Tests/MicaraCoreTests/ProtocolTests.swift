// JSON littéraux copiés des formes réellement émises par `server/signal.js` et
// `bridge/renderer/src/engine.js` : c'est le contrat qu'on ne peut pas dévier
// sans casser la négociation WebRTC en silence.

import Foundation
import Testing
@testable import MicaraCore

private func decode(_ json: String) throws -> IncomingMessage {
    try IncomingMessage.decode(Data(json.utf8))
}

@Suite("Serveur → bridge")
struct IncomingMessageTests {
    @Test func welcomeAvecIceServersEnTableau() throws {
        let json = """
        {"type":"welcome","role":"bridge","space":{"secretCode":"aB3xY7"},"iceServers":[
          {"urls":["turn:turn.cloudflare.com:3478?transport=udp","turn:turn.cloudflare.com:3478?transport=tcp"],
           "username":"u123","credential":"c456"}]}
        """
        guard case let .welcome(code, servers) = try decode(json) else {
            Issue.record("welcome attendu"); return
        }
        #expect(code == "aB3xY7")
        #expect(servers == [IceServer(
            urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turn:turn.cloudflare.com:3478?transport=tcp"],
            username: "u123", credential: "c456")])
    }

    @Test func welcomeAvecUrlsEnChaineEtSansCredentials() throws {
        let json = #"{"type":"welcome","role":"bridge","space":{"secretCode":"ABCDEF"},"iceServers":[{"urls":"stun:stun.l.google.com:19302"}]}"#
        #expect(try decode(json) == .welcome(
            secretCode: "ABCDEF",
            iceServers: [IceServer(urls: ["stun:stun.l.google.com:19302"])]))
    }

    @Test func welcomeSansTurnConfigure() throws {
        // `server/turn.js` renvoie [] quand TURN_KEY_ID n'est pas configuré.
        let json = #"{"type":"welcome","role":"bridge","space":{"secretCode":"ABCDEF"},"iceServers":[]}"#
        #expect(try decode(json) == .welcome(secretCode: "ABCDEF", iceServers: []))
    }

    @Test func phoneJoinedIgnoreLActeur() throws {
        // `actor` existe encore côté serveur ; la réécriture ne l'affiche plus.
        #expect(try decode(#"{"type":"phone-joined","phoneId":"A1B2","actor":"Renard"}"#)
            == .phoneJoined(phoneId: "A1B2"))
    }

    @Test func phoneLeft() throws {
        #expect(try decode(#"{"type":"phone-left","phoneId":"A1B2"}"#) == .phoneLeft(phoneId: "A1B2"))
    }

    @Test func offer() throws {
        let json = #"{"type":"offer","sdp":{"type":"offer","sdp":"v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"},"phoneId":"A1B2","actor":"Renard"}"#
        guard case let .offer(phoneId, sdp) = try decode(json) else { Issue.record("offer attendu"); return }
        #expect(phoneId == "A1B2")
        #expect(sdp.type == "offer")
        #expect(sdp.sdp.hasPrefix("v=0"))
    }

    @Test func offerAvecSdpEnChaineNue() throws {
        let json = #"{"type":"offer","sdp":"v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n","phoneId":"A1B2"}"#
        guard case let .offer(_, sdp) = try decode(json) else { Issue.record("offer attendu"); return }
        #expect(sdp.type == "offer")
        #expect(sdp.sdp.hasPrefix("v=0"))
    }

    @Test func ice() throws {
        let json = #"{"type":"ice","candidate":{"candidate":"candidate:1 1 udp 2113937151 192.168.1.20 54321 typ host","sdpMid":"0","sdpMLineIndex":0},"phoneId":"A1B2","actor":"Renard"}"#
        #expect(try decode(json) == .ice(
            phoneId: "A1B2",
            candidate: IceCandidate(candidate: "candidate:1 1 udp 2113937151 192.168.1.20 54321 typ host",
                                    sdpMid: "0", sdpMLineIndex: 0)))
    }

    @Test func iceSansSdpMid() throws {
        let json = #"{"type":"ice","candidate":{"candidate":"candidate:2 1 udp 1 10.0.0.1 1 typ srflx"},"phoneId":"A1B2"}"#
        #expect(try decode(json) == .ice(
            phoneId: "A1B2",
            candidate: IceCandidate(candidate: "candidate:2 1 udp 1 10.0.0.1 1 typ srflx")))
    }

    @Test func typeInconnuNeFaitPasEchouerLeDecodage() throws {
        #expect(try decode(#"{"type":"bridge-status","connected":true}"#) == .unknown(type: "bridge-status"))
        #expect(try decode(#"{"type":"quelque-chose-de-neuf","x":[1,2,3]}"#) == .unknown(type: "quelque-chose-de-neuf"))
    }

    @Test func messageConnuMaisAmputeDevientUnknownPlutotQueDeJeter() throws {
        #expect(try decode(#"{"type":"phone-joined"}"#) == .unknown(type: "phone-joined"))
        #expect(try decode(#"{"type":"ice","phoneId":"A1B2"}"#) == .unknown(type: "ice"))
    }
}

@Suite("Bridge → serveur")
struct OutgoingMessageTests {
    private func fields(_ m: OutgoingMessage) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: m.encode())) as? [String: Any] ?? [:]
    }

    @Test func answer() throws {
        let f = try fields(.answer(phoneId: "A1B2", sdp: SessionDescription(type: "answer", sdp: "v=0\r\n")))
        #expect(f["type"] as? String == "answer")
        #expect(f["phoneId"] as? String == "A1B2")
        let sdp = f["sdp"] as? [String: Any]
        #expect(sdp?["type"] as? String == "answer")
        #expect(sdp?["sdp"] as? String == "v=0\r\n")
        // Pas de clé parasite : le serveur relaie l'objet tel quel au téléphone.
        #expect(f["candidate"] == nil)
        #expect(f["live"] == nil)
    }

    @Test func ice() throws {
        let f = try fields(.ice(phoneId: "A1B2", candidate: IceCandidate(
            candidate: "candidate:1 1 udp 2113937151 192.168.1.20 54321 typ host",
            sdpMid: "0", sdpMLineIndex: 0)))
        #expect(f["type"] as? String == "ice")
        #expect(f["phoneId"] as? String == "A1B2")
        let c = f["candidate"] as? [String: Any]
        #expect(c?["candidate"] as? String == "candidate:1 1 udp 2113937151 192.168.1.20 54321 typ host")
        #expect(c?["sdpMid"] as? String == "0")
        #expect(c?["sdpMLineIndex"] as? Int == 0)
        #expect(f["sdp"] == nil)
    }

    @Test func streamState() throws {
        let f = try fields(.streamState(phoneId: "A1B2", live: false))
        #expect(f["type"] as? String == "stream-state")
        #expect(f["phoneId"] as? String == "A1B2")
        #expect(f["live"] as? Bool == false)
    }

    // Aller-retour : ce que le bridge émet, le bridge sait le relire — c'est
    // exactement l'objet que le serveur relaie au téléphone (`{...msg, from}`).
    @Test func allerRetourIce() throws {
        let cand = IceCandidate(candidate: "candidate:1 1 udp 1 1.2.3.4 1 typ host", sdpMid: "0", sdpMLineIndex: 0)
        guard case let .ice(pid, back) = try IncomingMessage.decode(
            OutgoingMessage.ice(phoneId: "A1B2", candidate: cand).encode()) else {
            Issue.record("ice attendu"); return
        }
        #expect(pid == "A1B2")
        #expect(back == cand)
    }

    @Test func allerRetourSessionDescription() throws {
        let sdp = SessionDescription(type: "answer", sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n")
        let data = try JSONEncoder().encode(sdp)
        #expect(try JSONDecoder().decode(SessionDescription.self, from: data) == sdp)
    }
}

@Suite("Codes de fermeture")
struct CloseCodeTests {
    @Test func tableDuReadme() {
        #expect(CloseCode.missingParam == 4000)
        #expect(CloseCode.invalidToken == 4001)
        #expect(CloseCode.spaceNotFound == 4002)
        #expect(CloseCode.bridgeAlreadyConnected == 4003)
        #expect(CloseCode.invalidCode == 4004)
        #expect(CloseCode.spaceDisabled == 4005)
        #expect(CloseCode.accountDisabled == 4006)
        #expect(CloseCode.adminDisconnect == 4007)
        #expect(CloseCode.spaceFull == 4008)
        #expect(CloseCode.describe(4001) == "jeton invalide")
        #expect(CloseCode.describe(4008) == "espace plein")
        #expect(CloseCode.describe(4010) == "réunion terminée")
        // Un code WebSocket standard n'est pas du ressort de Micara.
        #expect(CloseCode.describe(1006) == nil)
    }
}
