import Foundation
import Network
import Security
import CryptoKit
import SquadKit

// SquadKit over the local network: Bonjour to find a squad's leader, TCP with TLS keyed per
// link, and SquadKit's length-prefixed JSON frames. Works on home Wi-Fi, on a mesh that reflects
// mDNS, and, with peer-to-peer Wi-Fi, with no router. The squad's logic stays in SquadKit; this
// only moves bytes.
//
// Every link is keyed by a `LinkKey`: an invite's, the typed code's, or a member credential's.
// The leader's listener holds all the keys that may connect right now and TLS picks by the name
// the device gives. TLS doesn't tell the listener which key it picked, so a device's first frame
// says which, with a proof tied to this TLS session (docs/WIRE.md, "The local link").

/// Which app's squads to find and talk to. Two apps with different services never see each
/// other's squads, and their links don't share keys.
public struct SquadService: Hashable, Sendable {
    /// The Bonjour service type every leader advertises, like "_squadz._tcp".
    public var type: String
    /// Mixed into every TLS key.
    public var app: String
    /// The URL scheme of this app's invites, like "squadz".
    public var scheme: String

    public init(type: String, app: String, scheme: String) {
        self.type = type
        self.app = app
        self.scheme = scheme
    }

    public static let squadz = SquadService(type: "_squadz._tcp", app: "Squadz", scheme: "squadz")

    /// TXT record keys.
    public enum Key {
        public static let role = "role"
        public static let protocolVersion = "v"
        /// `SquadID.tag`: finds a squad again whatever it is called.
        public static let tag = "tag"
    }

    /// The TLS pre-shared key for a link key.
    func tlsKey(_ key: LinkKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("\(app) squad link".utf8), using: SymmetricKey(data: key.key)))
    }

    static let exporterLabel = "squad link v1"
}

public extension NWParameters {
    /// TCP with TLS and pre-shared keys: one key for a device connecting, every key that may
    /// connect for a leader listening. Nothing travels in the clear. Peer-to-peer Wi-Fi is allowed.
    static func squadLink(keys: [LinkKey], service: SquadService = .squadz) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.noDelay = true

        let tls = NWProtocolTLS.Options()
        for key in keys {
            let psk = service.tlsKey(key)
            let identity = Data(key.identity.utf8)
            psk.withUnsafeBytes { pskBytes in
                identity.withUnsafeBytes { idBytes in
                    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                            DispatchData(bytes: pskBytes) as __DispatchData,
                                                            DispatchData(bytes: idBytes) as __DispatchData)
                }
            }
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// What a link runs over: a TLS connection on the local network, or a relay. It moves bytes and
/// says when it is up; `SquadConnection` does the rest. Everything happens on the link's queue.
protocol LinkPipe: AnyObject {
    var onEvent: ((PipeEvent) -> Void)? { get set }
    func start()
    func send(_ bytes: Data, thenClose: Bool)
    func cancel()
    /// Closes the link, telling the other end its key wasn't accepted where the pipe can say so.
    func refuse()
}

enum PipeEvent {
    /// The pipe is up. `binding` is a value both ends of it share and neither chose alone; nil
    /// if there isn't one, and then the link can't be trusted.
    case up(binding: Data?)
    case bytes(Data)
    case failed(String)
    case closed
}

/// A TLS connection keyed per link (`NWParameters.squadLink`).
final class LocalPipe: LinkPipe {
    var onEvent: ((PipeEvent) -> Void)?
    let connection: NWConnection
    private let queue: DispatchQueue

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.onEvent?(.up(binding: self.binding()))
                self.receive()
            case let .failed(error):
                self.onEvent?(.failed(Self.describe(error)))
            case let .waiting(error):
                // TLS refusing the key shows up here: a wrong code, an invite that's closed, a
                // credential that was revoked.
                self.onEvent?(.failed(Self.describe(error)))
                self.connection.cancel()
            case .cancelled:
                self.onEvent?(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ bytes: Data, thenClose: Bool) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            if thenClose { self?.connection.cancel() }
        })
    }

    func cancel() { connection.cancel() }
    func refuse() { connection.cancel() }

    /// A value both ends of this TLS session share and nobody else can choose (RFC 5705).
    private func binding() -> Data? {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let label = SquadService.exporterLabel
        guard let secret = label.withCString({
            sec_protocol_metadata_create_secret(tls.securityProtocolMetadata, label.utf8.count, $0, 32)
        }) else { return nil }
        return Data(secret as DispatchData)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onEvent?(.bytes(data)) }
            if isComplete {
                self.connection.cancel()
            } else if let error {
                self.onEvent?(.failed(Self.describe(error)))
            } else {
                self.receive()
            }
        }
    }

    static func describe(_ error: NWError) -> String {
        // With a pre-shared key, a TLS handshake failure means the leader doesn't hold this key
        // (unknown identity, -9864) or holds another under the same name (bad MAC, -9820).
        if case let .tls(status) = error { return "\(SquadConnection.refusedKey) (TLS \(status))." }
        return String(describing: error)
    }
}

/// One link: a phone's (or a watcher's) connection to a leader, or the leader's
/// side of it. Everything happens on `queue`, including the callbacks.
public final class SquadConnection {
    public enum State: Equatable, Sendable {
        case connecting
        case ready
        case failed(String)
        case closed
    }

    public let peer: PeerID
    public private(set) var state: State = .connecting
    public var onMessage: ((SquadMessage) -> Void)?
    public var onState: ((State) -> Void)?

    /// On the leader's side: the name of the key this link proved it holds, once it has.
    public private(set) var identity: String?
    /// True for a link that goes through a relay.
    public let isRelayed: Bool

    private let pipe: LinkPipe
    private let queue: DispatchQueue
    private var reader = SquadWire.FrameReader()
    private var seq = 0
    private var binding: Data?
    /// Connecting: the key to prove.
    private let key: LinkKey?
    /// What the first frame claims. Tests change it to claim a key the link wasn't made with.
    var claim: LinkKey?
    /// Accepting: the keys a device may prove.
    private let accepted: [String: LinkKey]

    /// The leader's side of a link a device opened.
    init(accepting pipe: LinkPipe, peer: PeerID, keys: [LinkKey], relayed: Bool, queue: DispatchQueue) {
        self.pipe = pipe
        self.peer = peer
        self.queue = queue
        isRelayed = relayed
        key = nil
        accepted = Dictionary(keys.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// A device's side of a link, over any pipe.
    init(over pipe: LinkPipe, key: LinkKey, relayed: Bool, queue: DispatchQueue) {
        self.pipe = pipe
        peer = PeerID("host")
        self.queue = queue
        isRelayed = relayed
        self.key = key
        claim = key
        accepted = [:]
    }

    /// Connects to a leader found by `SquadBrowser`, or to a host and port.
    public convenience init(to endpoint: NWEndpoint, key: LinkKey, service: SquadService = .squadz, queue: DispatchQueue = .main) {
        let connection = NWConnection(to: endpoint, using: .squadLink(keys: [key], service: service))
        self.init(over: LocalPipe(connection, queue: queue), key: key, relayed: false, queue: queue)
    }

    /// Connects to a squad's leader through a relay.
    public convenience init(through ticket: RelayTicket, squad: SquadID, key: LinkKey, queue: DispatchQueue = .main) {
        self.init(over: RelayMemberPipe(ticket: ticket, squad: squad, queue: queue), key: key, relayed: true, queue: queue)
    }

    /// Seconds to reach `.ready`. A key the leader doesn't hold can leave the handshake hanging (the other
    /// side just drops it), so a connection that hasn't come up by then fails.
    public var connectTimeout: TimeInterval = 8
    public static let timedOut = "No answer from the other device."
    static let refusedKey = "The leader's device didn't accept this device's key"

    public func start() {
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            guard let self, self.state == .connecting else { return }
            self.set(.failed(Self.timedOut))
            self.pipe.cancel()
        }
        pipe.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .up(binding):
                self.linked(binding)
            case let .bytes(data):
                self.received(data)
            case let .failed(why):
                self.set(.failed(why))
            case .closed:
                self.set(.closed)
            }
        }
        pipe.start()
    }

    /// - Parameter thenClose: closes the link once the message has gone.
    public func send(_ body: SquadMessage.Body, thenClose: Bool = false) {
        seq += 1
        guard let frame = try? SquadWire.encode(SquadMessage(seq: seq, body: body)) else { return }
        pipe.send(frame, thenClose: thenClose)
    }

    /// The pipe is up. A device says which key it holds; the leader's side waits to hear it.
    private func linked(_ binding: Data?) {
        guard let binding else { return fail("Couldn't secure the link.") }
        self.binding = binding
        if let claim {
            send(.link(LinkProof(id: claim.identity, proof: claim.proof(binding: binding))))
            set(.ready)
        }
    }

    /// The leader's side: nothing counts until the first frame proves a key.
    private func deliver(_ m: SquadMessage) {
        if key != nil || identity != nil { return onMessage?(m) ?? () }
        guard case let .link(proof) = m.body, let known = accepted[proof.id], let binding,
              known.accepts(proof.proof, binding: binding) else {
            set(.failed("A device connected without proving its key."))
            return pipe.refuse()
        }
        identity = proof.id
        set(.ready)
    }

    private func fail(_ why: String) {
        set(.failed(why))
        pipe.cancel()
    }

    public func cancel() {
        pipe.cancel()
    }

    private func set(_ s: State) {
        guard s != state else { return }
        // Once a link has failed or closed it stays that way.
        if case .failed = state { return }
        if state == .closed { return }
        state = s
        onState?(s)
    }

    private func received(_ data: Data) {
        do {
            for m in try reader.append(data) {
                guard state == .connecting || state == .ready else { return }
                deliver(m)
            }
        } catch {
            fail("Bad data from \(peer): \(error)")
        }
    }
}

/// The leader's side: advertises the squad over Bonjour and accepts connections. Wire it to a
/// `SquadCore`: tell the core when a link opens (`onOpened`), feed it what arrives (`onMessage`),
/// send what it returns (`send`), and after anything that changes who may connect give this the
/// core's `linkKeys` again (`setKeys`).
///
/// If the listener fails (the leader's device slept, the network changed), it starts a new one with the same
/// name, keys and port after a short pause; phones reconnect on their own (`SquadLinkClient`).
public final class SquadLinkHost {
    /// A link proved its key (`identity` names it). Called before any of its messages.
    public var onOpened: ((PeerID, String) -> Void)?
    public var onMessage: ((SquadMessage, PeerID) -> Void)?
    public var onPeerClosed: ((PeerID) -> Void)?
    public var onReady: ((UInt16) -> Void)?
    public var onFailed: ((String) -> Void)?
    public private(set) var connections: [PeerID: SquadConnection] = [:]
    /// The port phones connect to. It stays the same across restarts.
    public var port: UInt16? { lastPort }
    /// False for the moment a restart takes (a change of keys, or a failure). A phone that
    /// connects then is refused and tries again.
    public private(set) var isListening = false

    private var listener: NWListener?
    private var lastPort: UInt16?
    private var stopped = true
    private var keys: [LinkKey]
    private let name: String
    private let service: SquadService
    private let txt: [String: String]
    private let advertise: Bool
    private let queue: DispatchQueue
    /// Seconds before a failed listener is started again.
    public var restartDelay: TimeInterval = 1.5

    /// - Parameter txt: put the squad's tag here (`SquadService.Key.tag`), so its members find it
    ///   again if it is renamed.
    /// - Parameter advertise: off in tests, which connect to the port directly.
    public init(name: String, keys: [LinkKey], service: SquadService = .squadz, txt: [String: String] = [:],
                advertise: Bool = true, queue: DispatchQueue = .main) throws {
        self.name = name
        self.keys = keys
        self.service = service
        self.txt = txt
        self.advertise = advertise
        self.queue = queue
        listener = try makeListener(port: nil)
    }

    private func makeListener(port: UInt16?) throws -> NWListener {
        let params = NWParameters.squadLink(keys: keys, service: service)
        let l: NWListener
        if let port, let p = NWEndpoint.Port(rawValue: port) {
            params.allowLocalEndpointReuse = true
            l = try NWListener(using: params, on: p)
        } else {
            l = try NWListener(using: params)
        }
        if advertise {
            var record = NWTXTRecord()
            record[SquadService.Key.protocolVersion] = String(SquadProtocol.version)
            for (k, v) in txt { record[k] = v }
            l.service = NWListener.Service(name: name, type: service.type, txtRecord: record)
        }
        return l
    }

    public func start() {
        stopped = false
        guard let listener else { return }
        let accepting = keys
        listener.stateUpdateHandler = { [weak self, weak listener] s in
            guard let self, let listener, listener === self.listener else { return }
            switch s {
            case .ready:
                if let p = listener.port?.rawValue {
                    self.lastPort = p
                    self.isListening = true
                    self.onReady?(p)
                }
            case let .failed(e):
                self.isListening = false
                self.onFailed?(String(describing: e))
                self.restartSoon()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw, keys: accepting) }
        listener.start(queue: queue)
    }

    /// The keys that may connect from now on. A listener's keys are fixed when it starts, so a
    /// change starts a new listener on the same port. Links that are up stay up.
    public func setKeys(_ new: [LinkKey]) {
        guard Set(new) != Set(keys) else { return }
        keys = new
        restart()
    }

    /// Starts a fresh listener now, for example when the app comes back to the foreground.
    public func restart() {
        guard !stopped else { return }
        isListening = false
        guard let old = listener else { return replaceListener() }
        // The port is free only once the old listener has gone.
        listener = nil
        old.newConnectionHandler = nil
        old.stateUpdateHandler = { [weak self] s in
            guard case .cancelled = s, let self, self.listener == nil else { return }
            self.replaceListener()
        }
        old.cancel()
    }

    private func replaceListener() {
        guard !stopped, listener == nil else { return }
        listener = (try? makeListener(port: lastPort)) ?? (try? makeListener(port: nil))
        start()
    }

    private func restartSoon() {
        queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in self?.restart() }
    }

    private func accept(_ nw: NWConnection, keys: [LinkKey]) {
        let peer = PeerID(UUID().uuidString)
        let c = SquadConnection(accepting: LocalPipe(nw, queue: queue), peer: peer, keys: keys, relayed: false, queue: queue)
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

    public func send(_ outgoing: [Outgoing]) {
        for o in outgoing { connections[o.to]?.send(o.body, thenClose: o.thenClose) }
    }

    public func stop() {
        stopped = true
        isListening = false
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections = [:]
    }
}

/// Finds one squad's leader: by the squad's tag, or by its name when all there is is a typed code.
final class SquadFinder {
    private var browser: SquadBrowser?

    /// Calls back once, with the leader or with why it can't be used.
    func find(tag: String?, name: String, service: SquadService, queue: DispatchQueue,
              found: @escaping (Result<NWEndpoint, SquadLinkFailure>) -> Void) {
        let b = SquadBrowser(service: service, queue: queue)
        browser = b
        b.onChange = { [weak self, weak b] results in
            guard let self, let b, b === self.browser else { return }
            let match = results.first { tag != nil && $0.txt[SquadService.Key.tag] == tag } ?? results.first { $0.name == name }
            guard let f = match else { return }
            self.stop()
            guard f.isCompatible else {
                return found(.failure(SquadLinkFailure("\(f.name) runs protocol v\(f.protocolVersion.map(String.init) ?? "?"); this app speaks v\(SquadProtocol.version). Update both.")))
            }
            found(.success(f.endpoint))
        }
        b.start()
    }

    func stop() {
        browser?.stop()
        browser = nil
    }
}

public struct SquadLinkFailure: Error, Equatable, Sendable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
}

/// Joins a squad once: connects on an invite, asks to join, checks the leader's answer and hands
/// back the credential to keep. Call it only after the person has agreed to join: scanning a QR
/// code alone must not start this.
public final class SquadEnroller {
    public var onDone: ((Result<MemberCredential, SquadLinkFailure>) -> Void)?
    /// For tests and fixed hosts: connect here instead of browsing.
    public var fixedEndpoint: NWEndpoint?
    /// Seconds to find the squad and get its answer.
    public var timeout: TimeInterval = 20
    /// With an invite that names a relay: seconds to look for the squad on this network before
    /// going through the relay.
    public var relayAfter: TimeInterval = 3

    private let invite: SquadInvite?
    private let squadName: String
    private let key: LinkKey
    private let request: EnrolmentRequest
    private let service: SquadService
    private let queue: DispatchQueue
    private let finder = SquadFinder()
    private var connection: SquadConnection?
    private var joiner: RelayJoiner?
    /// Joined on this network; still asking the relay for a ticket.
    private var pending: MemberCredential?
    private var finished = false

    /// With an invite from a QR code. The answer must come from the leader the invite names.
    public init(invite: SquadInvite, name: String, device: UUID, role: Hello.Role? = nil,
                service: SquadService = .squadz, queue: DispatchQueue = .main) {
        self.invite = invite
        squadName = invite.name
        key = invite.linkKey
        request = EnrolmentRequest(name: name, device: device, role: role)
        self.service = service
        self.queue = queue
    }

    /// With the typed code, on local Wi-Fi. There is no leader key to check the answer against,
    /// so whichever device holds the code and answers is trusted: prefer the QR code.
    public init(squadName: String, code: String, name: String, device: UUID, role: Hello.Role? = nil,
                service: SquadService = .squadz, queue: DispatchQueue = .main) {
        invite = nil
        self.squadName = squadName
        key = .code(code)
        request = EnrolmentRequest(name: name, device: device, role: role)
        self.service = service
        self.queue = queue
    }

    public func start(now: Date = Date()) {
        if let invite, invite.isExpired(now: now) { return finish(.failure(SquadLinkFailure("This invite has expired. Ask for a new one."))) }
        let relay = invite?.relay
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            if let joined = self.pending { return self.finish(.success(joined)) }
            self.finish(.failure(SquadLinkFailure(relay == nil
                ? "Couldn't reach \(self.squadName). Is its leader's device nearby and on the same network?"
                : "Couldn't reach \(self.squadName), on this network or through its relay.")))
        }
        if let fixedEndpoint { return connect(to: fixedEndpoint) }
        finder.find(tag: invite?.tag, name: squadName, service: service, queue: queue) { [weak self] found in
            guard let self, self.connection == nil, self.joiner == nil else { return }
            switch found {
            case let .success(endpoint): self.connect(to: endpoint)
            case let .failure(why): self.finish(.failure(why))
            }
        }
        guard let relay, let invite else { return }
        queue.asyncAfter(deadline: .now() + relayAfter) { [weak self] in
            guard let self, !self.finished, self.connection == nil, self.joiner == nil else { return }
            // Not on this network: get a ticket from the relay, then join through it.
            self.finder.stop()
            self.ticket(from: relay, invite: invite, timeout: self.timeout) { result in
                switch result {
                case let .success(ticket):
                    self.run(SquadConnection(through: ticket, squad: invite.squad, key: self.key, queue: self.queue), ticket: ticket)
                case let .failure(why):
                    self.finish(.failure(why))
                }
            }
        }
    }

    private func ticket(from relay: RelayAddress, invite: SquadInvite, timeout: TimeInterval,
                        done: @escaping (Result<RelayTicket, SquadLinkFailure>) -> Void) {
        let j = RelayJoiner(address: relay, queue: queue)
        joiner = j
        j.start(squad: invite.squad, key: invite.relayKey, timeout: timeout) { [weak self] result in
            guard let self, !self.finished else { return }
            self.joiner = nil
            done(result)
        }
    }

    public func cancel() {
        finished = true
        tearDown()
    }

    private func connect(to endpoint: NWEndpoint) {
        run(SquadConnection(to: endpoint, key: key, service: service, queue: queue), ticket: nil)
    }

    /// - Parameter ticket: the relay ticket this link runs on, to keep with the credential.
    private func run(_ c: SquadConnection, ticket: RelayTicket?) {
        guard !finished else { return }
        connection = c
        c.onState = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                c.send(.hello(self.request.hello))
            case let .failed(why):
                let closed = why.hasPrefix(SquadConnection.refusedKey)
                self.finish(.failure(SquadLinkFailure(closed ? (self.invite == nil ? "Couldn't join. Check the code, and that joining is open." : "This invite is no longer open. Ask for a new one.") : why)))
            case .closed:
                self.finish(.failure(SquadLinkFailure("The leader's device closed the link.")))
            case .connecting:
                break
            }
        }
        c.onMessage = { [weak self] m in
            guard let self else { return }
            switch m.body {
            case let .enrolled(answer):
                do {
                    var credential = try self.request.accept(answer, invite: self.invite)
                    credential.relay = ticket
                    self.joined(credential)
                } catch EnrolmentError.wrongLeader, EnrolmentError.wrongSquad {
                    self.finish(.failure(SquadLinkFailure("Another device answered for \(self.squadName). Not joined.")))
                } catch {
                    self.finish(.failure(SquadLinkFailure("The leader's answer didn't check out. Not joined.")))
                }
            case let .refused(why):
                self.finish(.failure(SquadLinkFailure(why)))
            default:
                break   // nothing else counts on an invite link
            }
        }
        c.start()
    }

    /// Joined. If the squad has a relay and this device joined on the local network, it asks the
    /// relay for a ticket while the invite is still open, so it can reach the squad from
    /// elsewhere later. Without one it is still a member; it just can't use the relay.
    private func joined(_ credential: MemberCredential) {
        guard credential.relay == nil, let invite, let relay = invite.relay else { return finish(.success(credential)) }
        pending = credential
        dropConnection()
        ticket(from: relay, invite: invite, timeout: 5) { [weak self] result in
            var credential = credential
            if case let .success(ticket) = result { credential.relay = ticket }
            self?.finish(.success(credential))
        }
    }

    private func finish(_ result: Result<MemberCredential, SquadLinkFailure>) {
        guard !finished else { return }
        finished = true
        tearDown()
        onDone?(result)
    }

    private func tearDown() {
        finder.stop()
        joiner?.cancel()
        joiner = nil
        dropConnection()
    }

    private func dropConnection() {
        let c = connection
        connection = nil
        c?.onState = nil
        c?.onMessage = nil
        c?.cancel()
    }
}

/// A phone's or watcher's link to a squad it has joined, that keeps itself up: it finds the
/// squad, connects with its credential, says hello, and after any drop (the leader's device
/// slept, Wi-Fi blinked) finds it again and reconnects as the same member. It stops only when
/// told to, or when the leader refuses it.
public final class SquadLinkClient {
    public enum Status: Equatable, Sendable {
        case searching
        case connecting
        case connected
        /// Lost the link; trying again.
        case reconnecting(String)
        /// Won't retry: removed from the squad, a reset, or an incompatible version.
        case stopped(String)
    }

    public private(set) var status: Status = .searching
    public var onStatus: ((Status) -> Void)?
    public var onMessage: ((SquadMessage) -> Void)?
    /// The leader's device moved to a new identity key and the old key vouched for it: save the
    /// credential again.
    public var onCredentialChanged: ((MemberCredential) -> Void)?

    public private(set) var credential: MemberCredential
    private let name: String
    private let device: UUID
    private let service: SquadService
    private let queue: DispatchQueue
    private let finder = SquadFinder()
    private var connection: SquadConnection?
    private var running = false
    private var attempt = 0
    /// Times in a row the leader's device has turned this credential down, never having linked.
    private var refusals = 0
    /// Seconds between attempts, growing to `maxDelay`.
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 8
    /// For tests and fixed hosts: connect here instead of browsing.
    public var fixedEndpoint: NWEndpoint?
    /// With a relay ticket: seconds to look for the squad on this network before going through
    /// the relay. Each new attempt looks here first.
    public var relayAfter: TimeInterval = 3
    /// True while the link runs through the relay.
    public var isRelayed: Bool { connection?.isRelayed ?? false }
    private var search = 0
    public static let notAccepted = "The leader's device no longer accepts this device. Ask for a new invite."

    public init(credential: MemberCredential, name: String, device: UUID, service: SquadService = .squadz,
                queue: DispatchQueue = .main) {
        self.credential = credential
        self.name = name
        self.device = device
        self.service = service
        self.queue = queue
    }

    public func start() {
        guard !running else { return }
        running = true
        attempt = 0
        refusals = 0
        find()
    }

    public func send(_ body: SquadMessage.Body) {
        guard status == .connected else { return }
        connection?.send(body)
    }

    /// Leaves: says bye and stops reconnecting.
    public func stop() {
        guard running else { return }
        if status == .connected { connection?.send(.bye) }
        running = false
        tearDown()
        set(.stopped("Left"))
    }

    /// Try again now (for example when the app returns to the foreground).
    public func retryNow() {
        guard running, status != .connected else { return }
        attempt = 0
        tearDown()
        find()
    }

    private func find() {
        guard running else { return }
        if let fixedEndpoint { return connect(to: fixedEndpoint) }
        set(attempt == 0 ? .searching : status)
        search += 1
        let this = search
        finder.find(tag: credential.squad.tag, name: credential.squadName, service: service, queue: queue) { [weak self] found in
            guard let self, self.connection == nil else { return }
            switch found {
            case let .success(endpoint): self.connect(to: endpoint)
            case let .failure(why): self.giveUp(why.reason)
            }
        }
        guard let ticket = credential.relay else { return }
        queue.asyncAfter(deadline: .now() + relayAfter) { [weak self] in
            guard let self, self.running, self.search == this, self.connection == nil else { return }
            self.finder.stop()
            self.run(SquadConnection(through: ticket, squad: self.credential.squad, key: self.credential.linkKey, queue: self.queue))
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        run(SquadConnection(to: endpoint, key: credential.linkKey, service: service, queue: queue))
    }

    private func run(_ c: SquadConnection) {
        guard running else { return }
        if attempt == 0 { set(.connecting) }
        connection = c
        c.onState = { [weak self, weak c] s in
            guard let self, let c, c === self.connection else { return }
            switch s {
            case .ready:
                c.send(.hello(Hello(name: self.name, device: self.device, role: self.credential.role)))
                // On the local network TLS has already checked this device's key. Through a
                // relay the leader's device checks it now, so the link counts once it answers.
                if !c.isRelayed { self.up() }
            case let .failed(why):
                // The leader's device turning the key down can be a restart that hasn't loaded its
                // keys yet, so try a few times before believing it.
                if why.hasPrefix(SquadConnection.refusedKey) {
                    self.refusals += 1
                    if self.refusals >= 3 { return self.giveUp(Self.notAccepted) }
                }
                self.dropped(why)
            case .closed:
                self.dropped("Connection closed")
            case .connecting:
                break
            }
        }
        c.onMessage = { [weak self] m in
            guard let self else { return }
            switch m.body {
            case let .refused(why):
                self.giveUp(why)
            case let .leaderKey(change):
                self.up()
                if self.credential.apply(change) { self.onCredentialChanged?(self.credential) }
            default:
                self.up()
            }
            self.onMessage?(m)
        }
        c.start()
    }

    private func up() {
        guard running, status != .connected else { return }
        attempt = 0
        refusals = 0
        set(.connected)
    }

    private func dropped(_ why: String) {
        guard running else { return }
        tearDown()
        attempt += 1
        set(.reconnecting(why))
        let delay = min(maxDelay, baseDelay * pow(2, Double(min(attempt - 1, 4))))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.find() }
    }

    private func giveUp(_ why: String) {
        running = false
        tearDown()
        set(.stopped(why))
    }

    private func tearDown() {
        search += 1
        finder.stop()
        let c = connection
        connection = nil
        c?.onState = nil
        c?.onMessage = nil
        c?.cancel()
    }

    private func set(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatus?(s)
    }
}

/// Finds squad leaders on the local network.
public final class SquadBrowser {
    public struct Found: Hashable, Identifiable, Sendable {
        public var name: String
        public var endpoint: NWEndpoint
        public var txt: [String: String]
        public var id: String { name }
        public var protocolVersion: Int? { txt[SquadService.Key.protocolVersion].flatMap(Int.init) }
        public var isCompatible: Bool { protocolVersion == SquadProtocol.version }
    }

    public var onChange: (([Found]) -> Void)?
    public var onFailed: ((String) -> Void)?
    private let browser: NWBrowser
    private let queue: DispatchQueue

    public init(service: SquadService = .squadz, queue: DispatchQueue = .main) {
        self.queue = queue
        let p = NWParameters()
        p.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: service.type, domain: nil), using: p)
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Found? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = r.metadata { txt = record.dictionary }
                return Found(name: name, endpoint: r.endpoint, txt: txt)
            }
            self?.onChange?(found.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { [weak self] s in
            if case let .failed(e) = s { self?.onFailed?(String(describing: e)) }
        }
        browser.start(queue: queue)
    }

    public func stop() { browser.cancel() }
}
