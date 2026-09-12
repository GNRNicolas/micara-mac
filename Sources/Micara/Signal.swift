// Signal.swift — signalling WebSocket + one WebRTC peer per phone.
//
// Port of the "signal" half of `bridge/renderer/src/engine.js` (handleSignal +
// setupPc) and of the WS transport that used to live in the Electron main
// process. Here everything is in one process: `URLSessionWebSocketTask`
// replaces `ws`, `LKRTCPeerConnection` replaces `RTCPeerConnection`.
//
// CONCURRENCY INVARIANT: the roster, the peer table and the iceServers are
// touched only from `queue` (a serial queue). WebRTC callbacks arrive on
// arbitrary threads: every one of them is bounced back onto `queue`. Callbacks
// towards the UI (`onPhones`, `onState`) leave on the main queue.

import Foundation
import LiveKitWebRTC
import MicaraCore

// MARK: - Log

// MARK: - Configuration

struct SignalConfig {
    /// HTTPS root of the server, e.g. `https://app.getmicara.com`. The WS URL is
    /// derived from it (`wss://…/ws`): one URL to configure, not two to keep in
    /// sync.
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

    /// Roster published on every change (main queue).
    var onPhones: (([PhoneDot]) -> Void)?
    /// Connection state (main queue).
    var onState: ((State) -> Void)?
    /// Space code received in the `welcome` (main queue) — this is what feeds
    /// the bar's QR.
    var onSecretCode: ((String) -> Void)?

    private let config: SignalConfig
    private let audio: AudioEngine
    private let queue = DispatchQueue(label: "com.getmicara.signal")

    /// One factory for the whole process: it carries the ADM (hence playout)
    /// and is expensive to create. Built with the `.audioEngine` module and
    /// `bypassVoiceProcessing = true` — AEC is done by OUR input engine, and two
    /// VPIO units on the same mic trip over each other.
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

    /// Reconnection: 1 s, then ×2 up to 30 s. Reset to 1 s on every `welcome`.
    private var backoff: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    /// `true` after `disconnect()` or a fatal code: no further attempt.
    private var stopped = false

    init(config: SignalConfig, audio: AudioEngine) {
        self.config = config
        self.audio = audio
        super.init()
    }

    // MARK: - Lifecycle

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
            AppLog.write("[signal] disconnected (local request)")
        }
    }

    // MARK: - WebSocket

    private func openSocket() {
        guard let url = config.webSocketURL else {
            AppLog.write("[signal] invalid server URL: \(config.serverURL)")
            emit(.disconnected(code: nil, reason: "invalid URL"))
            return
        }
        emit(.connecting)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: url)
        self.session = session
        socket = task
        task.resume()
        receiveNext()
        AppLog.write("[signal] connecting to \(url.host ?? "?")…")
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
                    // The server's clean close lands HERE too: the code is only
                    // readable on the task, not in the error.
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
            if let error { AppLog.write("[signal] send failed: \(error.localizedDescription)") }
        }
    }

    private func handleClose(code: Int?, reason: String?) {
        guard !stopped else { return }
        closeAllPeers()
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        let label = code.flatMap { CloseCode.describe($0) } ?? reason ?? "unknown cause"
        emit(.disconnected(code: code, reason: label))

        // FATAL codes: the token, the space or the account is at fault.
        // Retrying can fix nothing and would hammer the server (`authLimiter`)
        // with an invalid token — we stop and report, the user must act.
        let fatal = [
            CloseCode.invalidToken, CloseCode.bridgeAlreadyConnected,
            CloseCode.spaceDisabled, CloseCode.accountDisabled, CloseCode.adminDisconnect,
        ]
        if let code, fatal.contains(code) {
            stopped = true
            pruneTimer?.cancel()
            pruneTimer = nil
            AppLog.write("[signal] FATAL close \(code) (\(label)) — no reconnection")
            return
        }

        AppLog.write("[signal] close \(code.map(String.init) ?? "?") (\(label)) — retrying in \(Int(backoff)) s")
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
            AppLog.write("[signal] unreadable message ignored")
            return
        }
        switch message {
        case let .welcome(secretCode, servers):
            iceServers = servers
            backoff = 1
            emit(.connected)
            // Bridge reconnection: the old peers died with the WS and the
            // phones are about to re-offer. Start clean, otherwise a
            // setRemoteDescription lands on a `failed` peer.
            closeAllPeers()
            roster = PhoneRoster(ghostTTLMs: 30_000)
            publishRoster()
            if let secretCode {
                DispatchQueue.main.async { [weak self] in self?.onSecretCode?(secretCode) }
            }
            AppLog.write("[signal] welcome — \(servers.count) ICE servers")

        case let .phoneJoined(phoneId):
            roster.joined(id: phoneId, nowMs: nowMs())
            publishRoster()
            AppLog.write("[signal] phone \(phoneId): joined")

        case let .phoneLeft(phoneId):
            closePeer(phoneId)
            audio.removePhone(id: phoneId)
            roster.left(id: phoneId, nowMs: nowMs())
            publishRoster()
            AppLog.write("[signal] phone \(phoneId): left")

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
                if let error { AppLog.write("[signal] ICE \(phoneId) rejected: \(error.localizedDescription)") }
            }

        case let .unknown(type):
            AppLog.write("[signal] unknown type ignored: \(type)")
        }
    }

    // MARK: - WebRTC peers

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
            AppLog.write("[signal] could not create peer \(phoneId)")
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
                AppLog.write("[signal] setRemoteDescription \(phoneId): \(error.localizedDescription)")
                return
            }
            let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            pc.answer(for: constraints) { [weak self] sdp, error in
                guard let self, let sdp else {
                    AppLog.write("[signal] createAnswer \(phoneId): \(error?.localizedDescription ?? "?")")
                    return
                }
                pc.setLocalDescription(sdp) { [weak self] error in
                    guard let self else { return }
                    if let error {
                        AppLog.write("[signal] setLocalDescription \(phoneId): \(error.localizedDescription)")
                        return
                    }
                    queue.async {
                        self.send(.answer(phoneId: phoneId,
                                          sdp: SessionDescription(type: "answer", sdp: sdp.sdp)))
                        AppLog.write("[signal] answer sent to \(phoneId)")
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

    // MARK: - Peer callbacks (always bounced back onto `queue`)

    fileprivate func peerDidReceive(track: LKRTCAudioTrack, phoneId: String) {
        queue.async { [self] in
            guard pcs[phoneId] != nil else { return }
            // `engine.js` TRAP: `ontrack` comes BEFORE `ICE connected`. We hook
            // it up anyway — waiting for the connected state misses the start of
            // speech, and the track simply delivers nothing until the first
            // packets arrive.
            audio.addPhone(id: phoneId, track: track)
            AppLog.write("[signal] phone \(phoneId): track wired into the mixer")
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
                // Transient: it often heals by itself. We show it in orange (a
                // "reconnecting" dot) but do not alert the server — the JS only
                // reported `live:false` on `failed`.
                roster.mediaLost(id: phoneId, nowMs: nowMs())
                publishRoster()
                AppLog.write("[signal] phone \(phoneId): link lost (transient)")
            case .connected, .completed:
                roster.mediaRestored(id: phoneId, nowMs: nowMs())
                publishRoster()
                send(.streamState(phoneId: phoneId, live: true))
                AppLog.write("[signal] phone \(phoneId): link established")
            case .failed, .closed:
                // A FAILURE MUST BE VISIBLE (06/09): a room mic that dies
                // silently is worse than a mic that dies. We say so in the log,
                // in the roster (the dot goes after 30 s) and to the server.
                closePeer(phoneId)
                audio.removePhone(id: phoneId)
                roster.left(id: phoneId, nowMs: nowMs())
                publishRoster()
                send(.streamState(phoneId: phoneId, live: false))
                AppLog.write("[signal] phone \(phoneId): connection lost — no longer transmitting")
            default:
                break
            }
        }
    }

    // MARK: - Roster

    /// The roster ages on its own: a ghost disappears 30 s after it was lost.
    /// Without this timer an orange dot would stay on screen forever, as long as
    /// no other event triggered a `prune`.
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

// MARK: - WebSocket close

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

// MARK: - Peer delegate

/// One delegate per phone: it is what carries the `phoneId`, which the WebRTC
/// API transports nowhere. A separate object from the client so we never have
/// to find the phone back by `LKRTCPeerConnection` identity.
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
