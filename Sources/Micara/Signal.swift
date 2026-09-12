// Signal.swift — WebSocket de signalisation + un pair WebRTC par téléphone.
//
// Portage de la partie « signal » de `bridge/renderer/src/engine.js` (handleSignal
// + setupPc) et du transport WS que portait le processus principal Electron.
// Ici tout est dans le même process : `URLSessionWebSocketTask` remplace `ws`,
// `LKRTCPeerConnection` remplace `RTCPeerConnection`.
//
// INVARIANT DE CONCURRENCE : le roster, la table des pairs et les iceServers ne
// sont touchés que depuis `queue` (une file série). Les callbacks WebRTC
// arrivent sur des threads quelconques : ils sont tous réinjectés dans `queue`.
// Les callbacks vers l'UI (`onPhones`, `onState`) partent sur la main queue.

import Foundation
import LiveKitWebRTC
import MicaraCore

// MARK: - Journal

// MARK: - Configuration

struct SignalConfig {
    /// Racine HTTPS du serveur, p. ex. `https://app.getmicara.com`. Le WS en est
    /// dérivé (`wss://…/ws`) : une seule URL à configurer, pas deux à garder
    /// cohérentes.
    var serverURL: URL
    var token: String

    init(serverURL: URL, token: String) {
        self.serverURL = serverURL
        self.token = token
    }

    /// `wss://…/ws?token=…&role=bridge`
    var webSocketURL: URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/ws"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "role", value: "bridge"),
        ]
        return components.url
    }
}

// MARK: - Client

final class SignalClient: NSObject {

    enum State: Equatable {
        case connecting
        case connected
        case disconnected(code: Int?, reason: String?)
    }

    /// Roster publié à chaque changement (main queue).
    var onPhones: (([PhoneDot]) -> Void)?
    /// État de la connexion (main queue).
    var onState: ((State) -> Void)?
    /// Code d'espace reçu dans le `welcome` (main queue) — c'est lui qui nourrit
    /// le QR de la barre.
    var onSecretCode: ((String) -> Void)?

    private let config: SignalConfig
    private let audio: AudioEngine
    private let queue = DispatchQueue(label: "com.getmicara.signal")

    /// Une seule factory pour tout le process : elle porte l'ADM (donc le
    /// playout) et son coût de création est élevé. Créée avec le module
    /// `.audioEngine` et `bypassVoiceProcessing = true` — l'AEC est faite par
    /// NOTRE moteur d'entrée ; deux VPIO sur le même micro se marchent dessus.
    private static let factory: LKRTCPeerConnectionFactory = {
        LKRTCPeerConnectionFactory(
            audioDeviceModuleType: .audioEngine,
            bypassVoiceProcessing: true,
            encoderFactory: nil,
            decoderFactory: nil,
            audioProcessingModule: nil
        )
    }()

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pcs: [String: LKRTCPeerConnection] = [:]
    private var handles: [String: PeerHandle] = [:]
    private var iceServers: [IceServer] = []
    private var roster = PhoneRoster(ghostTTLMs: 30_000)
    private var pruneTimer: DispatchSourceTimer?

    /// Reconnexion : 1 s, puis ×2 jusqu'à 30 s. Remis à 1 s à chaque `welcome`.
    private var backoff: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    /// `true` après `disconnect()` ou un code fatal : plus aucune tentative.
    private var stopped = false

    init(config: SignalConfig, audio: AudioEngine) {
        self.config = config
        self.audio = audio
        super.init()
    }

    // MARK: - Cycle de vie

    func connect() {
        queue.async { [self] in
            stopped = false
            backoff = 1
            openSocket()
            startPruneTimer()
        }
    }

    func disconnect() {
        queue.async { [self] in
            stopped = true
            reconnectWork?.cancel()
            reconnectWork = nil
            pruneTimer?.cancel()
            pruneTimer = nil
            closeAllPeers()
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            session?.invalidateAndCancel()
            session = nil
            roster = PhoneRoster(ghostTTLMs: 30_000)
            publishRoster()
            emit(.disconnected(code: nil, reason: nil))
            AppLog.write("[signal] déconnecté (demande locale)")
        }
    }

    // MARK: - WebSocket

    private func openSocket() {
        guard let url = config.webSocketURL else {
            AppLog.write("[signal] URL de serveur invalide : \(config.serverURL)")
            emit(.disconnected(code: nil, reason: "URL invalide"))
            return
        }
        emit(.connecting)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        socket = task
        task.resume()
        receiveNext()
        AppLog.write("[signal] connexion à \(url.host ?? "?")…")
    }

    private func receiveNext() {
        socket?.receive { [weak self] result in
            guard let self else { return }
            queue.async {
                switch result {
                case let .success(message):
                    switch message {
                    case let .data(data): self.handle(data: data)
                    case let .string(text): self.handle(data: Data(text.utf8))
                    @unknown default: break
                    }
                    self.receiveNext()
                case let .failure(error):
                    // La fermeture propre du serveur arrive ICI aussi : le code
                    // n'est lisible que sur la tâche, pas dans l'erreur.
                    let code = self.socket.map { Int($0.closeCode.rawValue) }
                    self.handleClose(code: code == 0 ? nil : code, reason: error.localizedDescription)
                }
            }
        }
    }

    private func send(_ message: OutgoingMessage) {
        guard let data = try? message.encode(),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { error in
            if let error { AppLog.write("[signal] envoi échoué : \(error.localizedDescription)") }
        }
    }

    private func handleClose(code: Int?, reason: String?) {
        guard !stopped else { return }
        closeAllPeers()
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        let label = code.flatMap { CloseCode.describe($0) } ?? reason ?? "cause inconnue"
        emit(.disconnected(code: code, reason: label))

        // Codes FATALS : le jeton, l'espace ou le compte sont en cause. Retenter
        // ne peut rien réparer et martèlerait le serveur (`authLimiter`) avec un
        // jeton invalide — on s'arrête et on remonte, l'utilisateur doit agir.
        let fatal = [
            CloseCode.invalidToken, CloseCode.bridgeAlreadyConnected,
            CloseCode.spaceDisabled, CloseCode.accountDisabled, CloseCode.adminDisconnect,
        ]
        if let code, fatal.contains(code) {
            stopped = true
            pruneTimer?.cancel()
            pruneTimer = nil
            AppLog.write("[signal] fermeture FATALE \(code) (\(label)) — pas de reconnexion")
            return
        }

        AppLog.write("[signal] fermeture \(code.map(String.init) ?? "?") (\(label)) — nouvelle tentative dans \(Int(backoff)) s")
        let work = DispatchWorkItem { [weak self] in
            guard let self, !stopped else { return }
            openSocket()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + backoff, execute: work)
        backoff = min(backoff * 2, 30)
    }

    // MARK: - Messages

    private func handle(data: Data) {
        guard let message = try? IncomingMessage.decode(data) else {
            AppLog.write("[signal] message illisible ignoré")
            return
        }
        switch message {
        case let .welcome(secretCode, servers):
            iceServers = servers
            backoff = 1
            emit(.connected)
            // Reconnexion du bridge : les anciens pairs sont morts avec le WS et
            // les téléphones vont ré-offrir. Repartir propre, sinon un
            // setRemoteDescription tombe sur un pair `failed`.
            closeAllPeers()
            roster = PhoneRoster(ghostTTLMs: 30_000)
            publishRoster()
            if let secretCode {
                DispatchQueue.main.async { [weak self] in self?.onSecretCode?(secretCode) }
            }
            AppLog.write("[signal] welcome — \(servers.count) serveurs ICE")

        case let .phoneJoined(phoneId):
            roster.joined(id: phoneId, nowMs: nowMs())
            publishRoster()
            AppLog.write("[signal] téléphone \(phoneId) : arrivé")

        case let .phoneLeft(phoneId):
            closePeer(phoneId)
            audio.removePhone(id: phoneId)
            roster.left(id: phoneId, nowMs: nowMs())
            publishRoster()
            AppLog.write("[signal] téléphone \(phoneId) : parti")

        case let .offer(phoneId, sdp):
            answer(phoneId: phoneId, offer: sdp)

        case let .ice(phoneId, candidate):
            guard let pc = pcs[phoneId] else { return }
            let ice = LKRTCIceCandidate(
                sdp: candidate.candidate,
                sdpMLineIndex: candidate.sdpMLineIndex ?? 0,
                sdpMid: candidate.sdpMid
            )
            pc.add(ice) { error in
                if let error { AppLog.write("[signal] ICE \(phoneId) refusé : \(error.localizedDescription)") }
            }

        case let .unknown(type):
            AppLog.write("[signal] type inconnu ignoré : \(type)")
        }
    }

    // MARK: - Pairs WebRTC

    private func peerConnection(for phoneId: String) -> LKRTCPeerConnection? {
        if let existing = pcs[phoneId] { return existing }
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map {
            LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let handle = PeerHandle(phoneId: phoneId, client: self)
        guard let pc = Self.factory.peerConnection(
            with: configuration, constraints: constraints, delegate: handle
        ) else {
            AppLog.write("[signal] impossible de créer le pair \(phoneId)")
            return nil
        }
        pcs[phoneId] = pc
        handles[phoneId] = handle
        return pc
    }

    private func answer(phoneId: String, offer: SessionDescription) {
        guard let pc = peerConnection(for: phoneId) else { return }
        let remote = LKRTCSessionDescription(type: .offer, sdp: offer.sdp)
        pc.setRemoteDescription(remote) { [weak self] error in
            guard let self else { return }
            if let error {
                AppLog.write("[signal] setRemoteDescription \(phoneId) : \(error.localizedDescription)")
                return
            }
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { [weak self] sdp, error in
                guard let self, let sdp else {
                    AppLog.write("[signal] createAnswer \(phoneId) : \(error?.localizedDescription ?? "?")")
                    return
                }
                pc.setLocalDescription(sdp) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        AppLog.write("[signal] setLocalDescription \(phoneId) : \(error.localizedDescription)")
                        return
                    }
                    queue.async {
                        self.send(.answer(phoneId: phoneId,
                                          sdp: SessionDescription(type: "answer", sdp: sdp.sdp)))
                        AppLog.write("[signal] answer envoyée à \(phoneId)")
                    }
                }
            }
        }
    }

    private func closePeer(_ phoneId: String) {
        if let pc = pcs.removeValue(forKey: phoneId) { pc.close() }
        handles.removeValue(forKey: phoneId)
    }

    private func closeAllPeers() {
        for (phoneId, pc) in pcs {
            pc.close()
            audio.removePhone(id: phoneId)
        }
        pcs.removeAll()
        handles.removeAll()
    }

    // MARK: - Callbacks des pairs (toujours réinjectés dans `queue`)

    fileprivate func peerDidReceive(track: LKRTCAudioTrack, phoneId: String) {
        queue.async { [self] in
            guard pcs[phoneId] != nil else { return }
            // PIÈGE `engine.js` : `ontrack` PRÉCÈDE `ICE connected`. On branche
            // quand même — attendre l'état connecté fait rater le début de la
            // parole, et la piste ne livrera simplement rien avant l'arrivée
            // des premiers paquets.
            audio.addPhone(id: phoneId, track: track)
            AppLog.write("[signal] téléphone \(phoneId) : piste branchée au mixeur")
        }
    }

    fileprivate func peerDidGenerate(candidate: LKRTCIceCandidate, phoneId: String) {
        queue.async { [self] in
            send(.ice(phoneId: phoneId, candidate: IceCandidate(
                candidate: candidate.sdp,
                sdpMid: candidate.sdpMid,
                sdpMLineIndex: candidate.sdpMLineIndex
            )))
        }
    }

    fileprivate func peerDidChange(iceState: LKRTCIceConnectionState, phoneId: String) {
        queue.async { [self] in
            switch iceState {
            case .disconnected:
                // Transitoire : se répare souvent tout seul. On l'affiche en
                // orange (point « en reconnexion ») mais on n'alerte pas le
                // serveur — le JS ne signalait `live:false` que sur `failed`.
                roster.mediaLost(id: phoneId, nowMs: nowMs())
                publishRoster()
                AppLog.write("[signal] téléphone \(phoneId) : liaison perdue (transitoire)")
            case .connected, .completed:
                roster.mediaRestored(id: phoneId, nowMs: nowMs())
                publishRoster()
                send(.streamState(phoneId: phoneId, live: true))
                AppLog.write("[signal] téléphone \(phoneId) : liaison établie")
            case .failed, .closed:
                // LA PANNE DOIT SE VOIR (06/09) : un micro de salle qui lâche en
                // silence est pire qu'un micro qui lâche. On le dit au journal,
                // au roster (le point disparaît après 30 s) et au serveur.
                closePeer(phoneId)
                audio.removePhone(id: phoneId)
                roster.left(id: phoneId, nowMs: nowMs())
                publishRoster()
                send(.streamState(phoneId: phoneId, live: false))
                AppLog.write("[signal] téléphone \(phoneId) : connexion perdue — ne transmet plus")
            default:
                break
            }
        }
    }

    // MARK: - Roster

    /// Le roster vieillit tout seul : un fantôme disparaît 30 s après sa perte.
    /// Sans ce timer, un point orange resterait affiché indéfiniment tant
    /// qu'aucun autre événement ne provoquerait un `prune`.
    private func startPruneTimer() {
        guard pruneTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            roster.prune(nowMs: nowMs())
            publishRoster()
        }
        timer.resume()
        pruneTimer = timer
    }

    private func publishRoster() {
        let dots = roster.dots
        DispatchQueue.main.async { [weak self] in self?.onPhones?(dots) }
    }

    private func emit(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    private func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

// MARK: - Fermeture WebSocket

extension SignalClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let code = Int(closeCode.rawValue)
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }
        queue.async { [weak self] in
            self?.handleClose(code: code == 0 ? nil : code, reason: text)
        }
    }
}

// MARK: - Délégué d'un pair

/// Un délégué par téléphone : c'est lui qui porte le `phoneId`, que l'API
/// WebRTC ne transporte nulle part. Objet distinct du client pour ne pas avoir
/// à retrouver le téléphone par identité de `LKRTCPeerConnection`.
private final class PeerHandle: NSObject, LKRTCPeerConnectionDelegate {
    let phoneId: String
    weak var client: SignalClient?

    init(phoneId: String, client: SignalClient) {
        self.phoneId = phoneId
        self.client = client
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {
        guard let track = stream.audioTracks.first else { return }
        client?.peerDidReceive(track: track, phoneId: phoneId)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection,
                        didAdd rtpReceiver: LKRTCRtpReceiver,
                        streams mediaStreams: [LKRTCMediaStream]) {
        guard let track = rtpReceiver.track as? LKRTCAudioTrack else { return }
        client?.peerDidReceive(track: track, phoneId: phoneId)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        client?.peerDidGenerate(candidate: candidate, phoneId: phoneId)
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        client?.peerDidChange(iceState: newState, phoneId: phoneId)
    }
}
