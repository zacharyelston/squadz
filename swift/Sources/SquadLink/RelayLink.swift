import Foundation
import Network
import Security
import CryptoKit
import SquadKit

// SquadKit through a relay (docs/RELAY.md): for when a squad's devices aren't on one network.
// Each device holds a WebSocket to the relay. The leader's device opens the squad's room; a
// member's device opens a link into it; the relay passes the same frames the local link carries.
// The leader's device still asks every link for its key, as on the local network: the relay's
// say-so lets a device knock, never in. And every link is sealed between the two devices
// (docs/WIRE.md, "Sealed links"), so the relay carries frames it can't read or change.

enum RelayLink {
    static let away = "The leader's device isn't connected to the relay."
    static let ticketRefused = "The relay didn't accept this device."
    static let slow = "The relay is turning this network away for a few minutes."
    static let wrongCertificate = "The relay didn't show the certificate this squad expects."
}

/// One WebSocket to a relay. Text messages are the relay's own (JSON); binary ones are a squad's.
final class RelaySocket {
    enum Event {
        case ready
        case text([String: Any])
        case binary(Data)
        /// With why, if it wasn't a clean close.
        case ended(String?)
    }

    var onEvent: ((Event) -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var ended = false

    init(address: RelayAddress, queue: DispatchQueue) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.noDelay = true

        var tls: NWProtocolTLS.Options?
        if address.url.scheme?.lowercased() == "wss" {
            let options = NWProtocolTLS.Options()
            if let pin = address.pin {
                // The pinned certificate and no other, whoever signed it and whatever name it carries.
                sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                    let ref = sec_trust_copy_ref(trust).takeRetainedValue()
                    guard let leaf = (SecTrustCopyCertificateChain(ref) as? [SecCertificate])?.first else { return complete(false) }
                    complete(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)) == pin)
                }, queue)
            }
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = SquadWire.maxFrameBytes + 8
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        connection = NWConnection(to: .url(address.url.appendingPathComponent("v1/link")), using: parameters)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.onEvent?(.ready)
                self.receive()
            case let .failed(error), let .waiting(error):
                self.finish(Self.describe(error))
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(data, opcode: .text, thenClose: false)
    }

    func send(_ bytes: Data, thenClose: Bool = false) {
        send(bytes, opcode: .binary, thenClose: thenClose)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, thenClose: Bool) {
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            if thenClose { self?.cancel() }
        })
    }

    func cancel() {
        connection.cancel()
    }

    private func finish(_ why: String?) {
        guard !ended else { return }
        ended = true
        connection.cancel()
        onEvent?(.ended(why))
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.ended else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .text:
                if let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.onEvent?(.text(json)) }
            case .binary:
                self.onEvent?(.binary(data ?? Data()))
            case .close:
                return self.finish(nil)
            default:
                break
            }
            if let error { return self.finish(Self.describe(error)) }
            if meta == nil { return self.finish(nil) }
            if !self.ended { self.receive() }
        }
    }

    static func describe(_ error: NWError) -> String {
        if case .tls = error { return RelayLink.wrongCertificate }
        return "Couldn't reach the relay (\(error))."
    }
}

/// A member's device's link to the leader, through the relay.
final class RelayMemberPipe: LinkPipe {
    var onEvent: ((PipeEvent) -> Void)?
    private let socket: RelaySocket
    private let ticket: RelayTicket
    private let squad: SquadID
    private var opened = false

    init(ticket: RelayTicket, squad: SquadID, queue: DispatchQueue) {
        self.ticket = ticket
        self.squad = squad
        socket = RelaySocket(address: ticket.address, queue: queue)
    }

    func start() {
        socket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                self.socket.send(["t": "member", "squad": self.squad.raw.uuidString, "token": self.ticket.token.base64URL])
            case let .text(json):
                switch json["t"] as? String {
                case "open":
                    // The relay made this value up for this link and gave it to both ends.
                    self.opened = true
                    self.onEvent?(.up(binding: (json["nonce"] as? String).flatMap(Data.init(base64URL:)).flatMap { $0.count == 32 ? $0 : nil }))
                case "away":
                    self.onEvent?(.failed(RelayLink.away))
                case "refused":
                    if json["why"] as? String == "slow" {
                        self.onEvent?(.failed(RelayLink.slow))
                    } else if self.opened {
                        // The leader's device heard this link out and turned it down.
                        self.onEvent?(.failed("\(SquadConnection.refusedKey) (through the relay)."))
                    } else {
                        self.onEvent?(.failed(RelayLink.ticketRefused))
                    }
                default:
                    break
                }
            case let .binary(data):
                self.onEvent?(.bytes(data))
            case let .ended(why):
                self.onEvent?(why.map { .failed($0) } ?? .closed)
            }
        }
        socket.start()
    }

    func send(_ bytes: Data, thenClose: Bool) { socket.send(bytes, thenClose: thenClose) }
    func cancel() { socket.cancel() }
    func refuse() { socket.cancel() }
}

/// Gets a device its ticket for a squad's room, with an open invite's relay key.
final class RelayJoiner {
    private let socket: RelaySocket
    private let address: RelayAddress
    private let queue: DispatchQueue
    private var done: ((Result<RelayTicket, SquadLinkFailure>) -> Void)?

    init(address: RelayAddress, queue: DispatchQueue) {
        self.address = address
        self.queue = queue
        socket = RelaySocket(address: address, queue: queue)
    }

    func start(squad: SquadID, key: Data, timeout: TimeInterval, done: @escaping (Result<RelayTicket, SquadLinkFailure>) -> Void) {
        self.done = done
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(SquadLinkFailure("The relay didn't answer.")))
        }
        socket.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                self.socket.send(["t": "join", "squad": squad.raw.uuidString, "key": key.base64URL])
            case let .text(json):
                if json["t"] as? String == "joined", let device = json["device"] as? String,
                   let token = (json["token"] as? String).flatMap(Data.init(base64URL:)) {
                    self.finish(.success(RelayTicket(address: self.address, device: device, token: token)))
                } else if json["t"] as? String == "refused" {
                    switch json["why"] as? String {
                    case "slow": self.finish(.failure(SquadLinkFailure("Too many tries from this network. Wait ten minutes, then ask for a new invite.")))
                    case "full": self.finish(.failure(SquadLinkFailure("This squad has as many devices on its relay as it can take.")))
                    default: self.finish(.failure(SquadLinkFailure("This invite is no longer open. Ask for a new one.")))
                    }
                }
            case .binary:
                break
            case let .ended(why):
                self.finish(.failure(SquadLinkFailure(why ?? "The relay closed the connection.")))
            }
        }
        socket.start()
    }

    func cancel() {
        done = nil
        socket.cancel()
    }

    private func finish(_ result: Result<RelayTicket, SquadLinkFailure>) {
        guard let done else { return }
        self.done = nil
        socket.cancel()
        done(result)
    }
}

/// The leader's end of one member's link through the relay.
final class RelayHostPipe: LinkPipe {
    var onEvent: ((PipeEvent) -> Void)?
    let conn: UInt32
    private let nonce: Data?
    private weak var host: RelayLinkHost?
    private var done = false

    init(conn: UInt32, nonce: Data?, host: RelayLinkHost) {
        self.conn = conn
        self.nonce = nonce
        self.host = host
    }

    func start() { onEvent?(.up(binding: nonce)) }

    func send(_ bytes: Data, thenClose: Bool) {
        guard !done else { return }
        host?.forward(bytes, to: conn)
        if thenClose { finish(refused: false) }
    }

    func cancel() { finish(refused: false) }
    func refuse() { finish(refused: true) }

    private func finish(refused: Bool) {
        guard !done else { return }
        done = true
        host?.close(conn, refused: refused)
        onEvent?(.closed)
    }

    /// The relay says the member's device has gone.
    func ended() {
        guard !done else { return }
        done = true
        onEvent?(.closed)
    }

    func deliver(_ bytes: Data) {
        guard !done else { return }
        onEvent?(.bytes(bytes))
    }
}

/// The leader's side, through a relay: keeps the squad's room open and accepts the links members
/// open into it. Wire it to the `SquadCore` exactly as `SquadLinkHost` is wired, alongside it:
/// the two give their links different peers, and each ignores what is sent to the other's.
///
/// If the connection to the relay drops, it connects again; members' links come back on their own.
public final class RelayLinkHost {
    public enum Status: Equatable, Sendable {
        case connecting
        /// The room is open.
        case open
        /// Lost the relay; trying again.
        case retrying(String)
        /// Won't retry: the relay doesn't know this squad, or won't open a room for it.
        case stopped(String)
    }

    /// A link proved its key (`identity` names it). Called before any of its messages.
    public var onOpened: ((PeerID, String) -> Void)?
    public var onMessage: ((SquadMessage, PeerID) -> Void)?
    public var onPeerClosed: ((PeerID) -> Void)?
    /// The relay opened a room and gave the token that leads it: keep it (in the Keychain) and
    /// pass it back next time.
    public var onToken: ((Data) -> Void)?
    public var onStatus: ((Status) -> Void)?
    public private(set) var status: Status = .connecting
    public private(set) var connections: [PeerID: SquadConnection] = [:]
    /// Has the relay ever opened this squad's room? An invite should name the relay only then.
    public var hasRoom: Bool { token != nil }

    public let address: RelayAddress
    private let squad: SquadID
    private var token: Data?
    private var keys: [LinkKey]
    private var invites: [RelayInvite]
    private var sentInvites: [RelayInvite]?
    private let queue: DispatchQueue
    private var socket: RelaySocket?
    private var pipes: [UInt32: RelayHostPipe] = [:]
    private var running = false
    private var attempt = 0
    /// Seconds between attempts, growing to `maxDelay`.
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 15

    /// - Parameter token: nil for a squad the relay hasn't seen: it opens a room and `onToken` has the token.
    public init(address: RelayAddress, squad: SquadID, token: Data?, keys: [LinkKey], invites: [RelayInvite] = [],
                queue: DispatchQueue = .main) {
        self.address = address
        self.squad = squad
        self.token = token
        self.keys = keys
        self.invites = invites
        self.queue = queue
    }

    public func start() {
        guard !running else { return }
        running = true
        attempt = 0
        connect()
    }

    /// The keys that may connect from now on, and the invites the relay should recognise. Links
    /// that are up stay up.
    public func setKeys(_ new: [LinkKey], invites newInvites: [RelayInvite]) {
        keys = new
        invites = newInvites
        sendInvites()
    }

    public func send(_ outgoing: [Outgoing]) {
        for o in outgoing { connections[o.to]?.send(o.body, thenClose: o.thenClose) }
    }

    /// Try again now (for example when the app returns to the foreground).
    public func retryNow() {
        guard running, status != .open else { return }
        attempt = 0
        dropSocket()
        connect()
    }

    /// - Parameter endSquad: also has the relay forget the squad: its room, and every ticket.
    public func stop(endSquad: Bool = false) {
        running = false
        if endSquad, status == .open { socket?.send(["t": "end"]) }
        let old = socket
        // Let what was just sent go first.
        queue.asyncAfter(deadline: .now() + 0.5) { old?.cancel() }
        socket?.onEvent = nil
        socket = nil
        closeLinks()
    }

    private func connect() {
        guard running else { return }
        if attempt == 0 { set(.connecting) }
        let s = RelaySocket(address: address, queue: queue)
        socket = s
        s.onEvent = { [weak self, weak s] event in
            guard let self, let s, s === self.socket else { return }
            switch event {
            case .ready:
                if let token = self.token {
                    s.send(["t": "lead", "squad": self.squad.raw.uuidString, "token": token.base64URL])
                } else {
                    s.send(["t": "create", "squad": self.squad.raw.uuidString])
                }
            case let .text(json):
                self.heard(json)
            case let .binary(data):
                guard data.count >= 4 else { return }
                let conn = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                self.pipes[conn]?.deliver(Data(data.dropFirst(4)))
            case let .ended(why):
                self.lost(why ?? "The relay closed the connection.")
            }
        }
        s.start()
    }

    private func heard(_ json: [String: Any]) {
        switch json["t"] as? String {
        case "created":
            guard let new = (json["token"] as? String).flatMap(Data.init(base64URL:)) else { return }
            token = new
            onToken?(new)
            opened()
        case "ok":
            opened()
        case "refused":
            if json["why"] as? String == "slow" { return lost(RelayLink.slow) }
            running = false
            dropSocket()
            set(.stopped(token == nil ? "The relay wouldn't open a room for this squad." : "The relay no longer knows this squad."))
        case "open":
            guard let conn = (json["conn"] as? NSNumber)?.uint32Value else { return }
            accept(conn, nonce: (json["nonce"] as? String).flatMap(Data.init(base64URL:)).flatMap { $0.count == 32 ? $0 : nil })
        case "closed":
            guard let conn = (json["conn"] as? NSNumber)?.uint32Value else { return }
            pipes.removeValue(forKey: conn)?.ended()
        default:
            break
        }
    }

    private func opened() {
        attempt = 0
        sentInvites = nil
        set(.open)
        sendInvites()
    }

    private func sendInvites() {
        guard status == .open, sentInvites != invites else { return }
        sentInvites = invites
        socket?.send(["t": "invites", "list": invites.map { ["hash": $0.hash.hex, "exp": Int($0.expires.timeIntervalSince1970)] as [String: Any] }])
    }

    private func accept(_ conn: UInt32, nonce: Data?) {
        let peer = PeerID(UUID().uuidString)
        let pipe = RelayHostPipe(conn: conn, nonce: nonce, host: self)
        pipes[conn] = pipe
        let c = SquadConnection(accepting: pipe, peer: peer, keys: keys, relayed: true, queue: queue)
        c.onMessage = { [weak self] m in self?.onMessage?(m, peer) }
        c.onState = { [weak self, weak c] s in
            guard let self else { return }
            switch s {
            case .ready:
                if let identity = c?.identity { self.onOpened?(peer, identity) }
            case .failed, .closed:
                guard self.connections[peer] != nil else { return }
                self.connections[peer] = nil
                self.onPeerClosed?(peer)
            case .connecting:
                break
            }
        }
        connections[peer] = c
        c.start()
    }

    func forward(_ bytes: Data, to conn: UInt32) {
        var framed = withUnsafeBytes(of: conn.bigEndian) { Data($0) }
        framed.append(bytes)
        socket?.send(framed)
    }

    func close(_ conn: UInt32, refused: Bool) {
        guard pipes.removeValue(forKey: conn) != nil else { return }
        var message: [String: Any] = ["t": "close", "conn": Int(conn)]
        if refused { message["refused"] = true }
        socket?.send(message)
    }

    private func lost(_ why: String) {
        dropSocket()
        guard running else { return }
        attempt += 1
        set(.retrying(why))
        let delay = min(maxDelay, baseDelay * pow(2, Double(min(attempt - 1, 4))))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.socket == nil else { return }
            self.connect()
        }
    }

    private func dropSocket() {
        socket?.onEvent = nil
        socket?.cancel()
        socket = nil
        closeLinks()
    }

    private func closeLinks() {
        let open = pipes.values
        pipes = [:]
        for pipe in open { pipe.ended() }
        connections = [:]
    }

    private func set(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatus?(s)
    }
}
