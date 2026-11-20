import Foundation
import CoreGeo

/// The leader's device: the squad core running one mission. The core does what every squad
/// needs: join and rejoin, the roster, positions, orders, notes, check fire, observers and the
/// holds. The mission does the rest. Every input from a phone is untrusted data that this host
/// gates and commits.
///
/// Pure state: `handle` and the leader's actions return the messages to send.
public struct SquadCore<M: Mission> {
    public var squad: Squad
    /// The mission's own state. Whatever a mission does to itself, it can't lift a core hold:
    /// `holds` unions the core's with the mission's.
    public var mission: M
    public private(set) var revision: Int

    /// The root key and this device's identity key. Kept in the Keychain, never in a file.
    public private(set) var keys: LeaderKeys
    /// Every credential issued, without its secret. Save this with the squad.
    public private(set) var credentials: [CredentialRecord]
    /// Bumped by `resetSquad`. A credential from an earlier epoch no longer works.
    public private(set) var epoch: Int
    /// This squad's identity key changes, oldest first, for devices that pinned an earlier key.
    public private(set) var keyChanges: [LeaderKeyChange]
    /// Invites that are open (until each expires, is used up, or joining closes).
    public private(set) var invitations: [Invitation] = []
    /// The typed code, while joining is open. For local Wi-Fi only.
    public private(set) var joinCode: String?
    private var joinCodeExpires = Date.distantPast
    /// How each link proved itself, from the transport.
    private var links: [PeerID: LinkAuth] = [:]

    /// An open invite.
    public struct Invitation: Equatable, Sendable {
        public var secret: Data
        public var expires: Date
        /// Closed by the first device that joins with it.
        public var singleUse: Bool
        var identity: String
    }

    enum LinkAuth: Equatable {
        case code
        case invite(String)
        case member(Data)
    }

    public private(set) var peers: [PeerID: MemberID] = [:]
    /// Watchers. They get status, positions, orders and notes; what they send is ignored.
    public private(set) var observers: Set<PeerID> = []
    public private(set) var positions: [MemberID: MemberPosition] = [:]
    /// Whether members see each other's positions, as observers always do. The leader's choice:
    /// on for a squad that is out together, off where only the leader should know where people are.
    public var sharesPositions: Bool
    /// Whether members see each other's notes, like a chat room, as observers always do. Off,
    /// notes go to the leader only.
    public var sharesNotes: Bool
    /// The last thing that went wrong, for the leader's screen.
    public private(set) var lastProblem: String?
    /// Notes from members, oldest first (passed on to observers as they arrive).
    public private(set) var notes: [FieldNote] = []
    /// Orders sent this session, oldest first, and each recipient's latest answer.
    public private(set) var orders: [Order] = []
    public private(set) var acks: [UUID: [MemberID: OrderAck.Response]] = [:]
    /// Orders the leader took back. They stay in `orders`, for the record.
    public private(set) var cancelled: Set<UUID> = []
    /// What the squad was told, oldest first: members leaving or being removed.
    public private(set) var notices: [Notice] = []
    static var maxNoticesKept: Int { 50 }
    static var maxOrdersKept: Int { 100 }
    static var maxNotesKept: Int { 100 }
    static var notesOnJoin: Int { 50 }

    /// Check fire in force, from any member or this device. Only the leader lifts it.
    public private(set) var activeCheckFire: CheckFire?
    private var seenCheckFires: Set<UUID> = []

    /// A new squad, or one read back: `keys` from the Keychain, the rest from where the app
    /// saved it.
    public init(squad: Squad, mission: M, keys: LeaderKeys = LeaderKeys(), credentials: [CredentialRecord] = [],
                epoch: Int = 0, keyChanges: [LeaderKeyChange] = [], revision: Int = 0, sharesPositions: Bool = false,
                sharesNotes: Bool = false) {
        self.sharesPositions = sharesPositions
        self.sharesNotes = sharesNotes
        self.squad = squad
        self.mission = mission
        self.keys = keys
        self.credentials = credentials
        self.epoch = epoch
        self.keyChanges = keyChanges
        self.revision = revision
    }

    public var squadID: SquadID { squad.id }

    /// What the core knows, for the mission.
    public var view: CoreView {
        CoreView(squad: squad, positions: positions, peers: peers, observers: observers, checkFire: activeCheckFire)
    }

    // MARK: Holds

    /// Everything holding this squad right now: the core's and the mission's. Holds only add.
    public func holds(now: Date) -> Set<Hold> {
        let core = view
        return core.holds.union(mission.holds(core: core, now: now))
    }

    // MARK: Joining

    /// Opens joining and returns the invite to show as a QR code. Anyone who scans it before it
    /// expires can join, so show it only to the people it is for. `typedCode` also opens the
    /// six-character code (`joinCode`).
    public mutating func openJoining(now: Date, lifetime: TimeInterval = 15 * 60, typedCode: Bool = false,
                                     by device: String? = nil) -> SquadInvite {
        if typedCode {
            joinCode = joinCode ?? JoinCode.make()
            joinCodeExpires = now.addingTimeInterval(lifetime)
        }
        return invite(singleUse: false, now: now, lifetime: lifetime, by: device)
    }

    /// An invite for one person: the first device to join with it uses it up.
    public mutating func inviteOne(now: Date, lifetime: TimeInterval = 15 * 60, by device: String? = nil) -> SquadInvite {
        invite(singleUse: true, now: now, lifetime: lifetime, by: device)
    }

    /// Closes joining: every invite and the typed code stop working. Members aren't affected.
    public mutating func closeJoining() {
        invitations = []
        joinCode = nil
    }

    private mutating func invite(singleUse: Bool, now: Date, lifetime: TimeInterval, by device: String?) -> SquadInvite {
        invitations.removeAll { $0.expires <= now }
        let invite = SquadInvite(squad: squadID, name: squad.name, enrol: .random(16), leader: keys.fingerprint,
                                 expires: now.addingTimeInterval(lifetime), by: device)
        invitations.append(Invitation(secret: invite.enrol, expires: invite.expires, singleUse: singleUse,
                                      identity: invite.linkKey.identity))
        return invite
    }

    /// Every key a device may connect with right now. Give these to the transport again after
    /// anything that changes them: joining opened or closed, a device joined, a member removed.
    public func linkKeys(now: Date) -> [LinkKey] {
        var out = credentials.filter { !$0.revoked && $0.epoch == epoch }.map {
            LinkKey.member(credential: $0.id, secret: keys.memberSecret(squad: squadID, credential: $0.id, epoch: $0.epoch), squad: squadID)
        }
        out += invitations.filter { $0.expires > now }.map { LinkKey.invite(secret: $0.secret, squad: squadID) }
        if let joinCode, joinCodeExpires > now { out.append(.code(joinCode)) }
        return out
    }

    /// From the transport, once a link has proved which key it holds and before any of its
    /// messages. A link the core hasn't been told about can't join.
    public mutating func linkOpened(_ peer: PeerID, identity: String) {
        if identity == "code" {
            links[peer] = .code
        } else if identity.hasPrefix("e:") {
            links[peer] = .invite(identity)
        } else if identity.hasPrefix("m:"), let id = Data(hex: String(identity.dropFirst(2))) {
            links[peer] = .member(id)
        }
    }

    // MARK: Messages

    public mutating func handle(_ message: SquadMessage, from peer: PeerID, now: Date) -> [Outgoing] {
        guard message.protocolVersion == SquadProtocol.version else {
            return [Outgoing(to: peer, .refused("Protocol version \(message.protocolVersion); this squad speaks \(SquadProtocol.version). Update the app."))]
        }
        if case let .hello(hello) = message.body {
            if hello.role == .contributor {
                return [Outgoing(to: peer, .refused("This is a squad. It doesn't take contributions."))]
            }
            return join(hello, peer: peer, now: now)
        }
        if observers.contains(peer) {
            if case .bye = message.body { observers.remove(peer) }
            return []   // an observer can't act on the squad
        }
        guard let member = peers[peer] else { return [] }   // not joined: ignored

        switch message.body {
        case .bye:
            peers[peer] = nil
            return []
        case .leave:
            let name = squad.members.first { $0.id == member }?.name ?? "A member"
            return drop(member, notice: Notice(kind: .left, text: "\(name) left the squad.", member: member, time: now), now: now)
        case var .position(p):
            p.member = member
            positions[member] = p
            return report(p, except: peer)
        case var .note(n):
            n.author = squad.members.first { $0.id == member }?.name ?? n.author
            guard !notes.contains(where: { $0.id == n.id }) else { return [] }   // sent twice
            notes.append(n)
            if notes.count > Self.maxNotesKept { notes.removeFirst(notes.count - Self.maxNotesKept) }
            return [Outgoing(to: peer, .receipt(Receipt(id: n.id, status: .stored, detail: "Sent to \(squad.name)'s leader.")))]
                + passOn(n, except: peer)
        case let .orderAck(a):
            // Only from someone the order was for.
            guard let o = orders.first(where: { $0.id == a.order }), o.isFor(member), !cancelled.contains(o.id) else { return [] }
            acks[a.order, default: [:]][member] = a.response
            return []
        case let .checkFire(cf):
            return raiseCheckFire(cf, now: now)
        case let .mission(m):
            // Another mission, or another version of this one: not for this squad.
            guard m.id == M.id, m.version == M.version else { return [] }
            let core = view
            return finish(mission.handle(m.payload, from: member, peer: peer, core: core, now: now), now: now)
        case .hello, .link, .seal, .fileOffer, .fileChunk, .fileDone, .enrolled, .leaderKey, .welcome, .observing, .refused,
             .status, .order, .orderCancel, .receipt, .positions, .notice:
            return []   // the leader's own messages from a phone, or files (a squad doesn't take them): ignored
        }
    }

    private mutating func join(_ hello: Hello, peer: PeerID, now: Date) -> [Outgoing] {
        func refuse(_ why: String) -> [Outgoing] { [Outgoing(to: peer, .refused(why), thenClose: true)] }
        switch links[peer] {
        case nil:
            return refuse("This link hasn't shown a key.")
        case .code:
            guard joinCode != nil, joinCodeExpires > now else { return refuse("Joining is closed.") }
            return enrol(hello, peer: peer, now: now) ?? refuse("Couldn't join: update the app.")
        case let .invite(identity):
            guard let i = invitations.firstIndex(where: { $0.identity == identity && $0.expires > now }) else {
                return refuse("This invite has expired or was already used.")
            }
            guard let out = enrol(hello, peer: peer, now: now) else { return refuse("Couldn't join: update the app.") }
            if invitations[i].singleUse { invitations.remove(at: i) }
            return out
        case let .member(id):
            guard let record = credentials.first(where: { $0.id == id && !$0.revoked && $0.epoch == epoch }) else {
                return refuse("This device is no longer in the squad.")
            }
            return connect(record, peer: peer, now: now)
        }
    }

    /// A new device on an invite link: issues its credential. It isn't connected yet; it comes
    /// back on a link keyed by the credential. Every device that joins is a new member, whatever
    /// device ID it gives: the ID isn't proof of anything.
    private mutating func enrol(_ hello: Hello, peer: PeerID, now: Date) -> [Outgoing]? {
        guard hello.nonce.count == 16, let memberKey = hello.key else { return nil }
        let role: Hello.Role = hello.role == .observer ? .observer : .member
        let id = Data.random(16)
        let issued = now.roundedToWire
        guard let sealed = try? SealedCredential.seal(secret: keys.memberSecret(squad: squadID, credential: id, epoch: epoch),
                                                      id: id, epoch: epoch, issued: issued, squad: squadID, for: memberKey) else { return nil }
        var member: MemberID?
        if role == .member {
            let m = Member(name: hello.name, device: hello.device, role: mission.role(forNewMemberOf: squad))
            squad.members.append(m)
            member = m.id
        }
        credentials.append(CredentialRecord(id: id, member: member, role: role, name: hello.name, device: hello.device,
                                            epoch: epoch, issued: issued, revoked: false))
        let signature = keys.sign(Enrolled.signed(squad: squadID, member: member, role: role, nonce: hello.nonce,
                                                  memberKey: memberKey, credential: sealed))
        let answer = Enrolled(squad: squadID, name: squad.name, member: member, role: role, credential: sealed,
                              leader: keys.publicKey, signature: signature)
        return [Outgoing(to: peer, .enrolled(answer), thenClose: true)] + (member == nil ? [] : changed(now: now))
    }

    /// A device back on its credential. Who it is and what it may do come from the credential,
    /// not from its hello.
    private mutating func connect(_ record: CredentialRecord, peer: PeerID, now: Date) -> [Outgoing] {
        let changes = keyChanges.map { Outgoing(to: peer, .leaderKey($0)) }
        guard let id = record.member, squad.members.contains(where: { $0.id == id }) else {
            guard record.role == .observer else {
                return [Outgoing(to: peer, .refused("This device is no longer in the squad."), thenClose: true)]
            }
            peers[peer] = nil
            observers.insert(peer)
            let known = positions.values.sorted { $0.time < $1.time }
            return changes + [Outgoing(to: peer, .observing(squad))]
                + mission.observerWelcome(core: view).map { Outgoing.mission(M.self, to: peer, $0) }
                + [Outgoing(to: peer, .status(status(now: now)))]
                + (known.isEmpty ? [] : [Outgoing(to: peer, .positions(PositionsReport(squad: squadID, positions: known)))])
        }
        observers.remove(peer)
        peers = peers.filter { $0.value != id }   // a rejoin replaces the old link
        peers[peer] = id
        // Orders for this member that it hasn't finished, so a rejoin (or a late joiner) has them.
        let open = orders.filter { $0.isFor(id) && !cancelled.contains($0.id) && acks[$0.id]?[id] != .done && acks[$0.id]?[id] != .cannot }.suffix(10)
        let known = sharesPositions ? positions.values.filter { $0.member != id }.sorted { $0.time < $1.time } : []
        // What has been said, so someone who joins late or comes back can read up.
        let said = sharesNotes ? notes.suffix(Self.notesOnJoin).map { Outgoing(to: peer, .note($0)) } : []
        // And the ones taken back, in case it was away when they were.
        let taken = orders.filter { $0.isFor(id) && cancelled.contains($0.id) }.suffix(10)
        return changes + [Outgoing(to: peer, .welcome(Welcome(member: id, squad: squad)))]
            + open.map { Outgoing(to: peer, .order($0)) } + taken.map { Outgoing(to: peer, .orderCancel($0.id)) } + said + changed(now: now)
            + (known.isEmpty ? [] : [Outgoing(to: peer, .positions(PositionsReport(squad: squadID, positions: known)))])
    }

    /// A link went away without a bye (the transport noticed).
    public mutating func peerClosed(_ peer: PeerID) {
        peers[peer] = nil
        observers.remove(peer)
        links[peer] = nil
    }

    // MARK: The leader's actions

    public mutating func setRole(_ member: MemberID, _ role: MemberRole, now: Date) -> [Outgoing] {
        guard let i = squad.members.firstIndex(where: { $0.id == member }) else { return [] }
        squad.members[i].role = role
        return changed(now: now)
    }

    /// Takes a member off the roster and revokes their credential: their link closes and their
    /// device can't connect again without a new invite.
    public mutating func removeMember(_ member: MemberID, now: Date) -> [Outgoing] {
        guard let name = squad.members.first(where: { $0.id == member })?.name else { return [] }
        return drop(member, notice: Notice(kind: .removed, text: "\(name) was removed from the squad.", member: member, time: now), now: now)
    }

    /// Off the roster, credential revoked, and everyone who is left told why.
    private mutating func drop(_ member: MemberID, notice: Notice, now: Date) -> [Outgoing] {
        let ids = Set(credentials.filter { $0.member == member }.map(\.id))
        let closing = revoke(ids)
        squad.members.removeAll { $0.id == member }
        positions[member] = nil
        notices.append(notice)
        if notices.count > Self.maxNoticesKept { notices.removeFirst(notices.count - Self.maxNoticesKept) }
        let told = (Array(peers.keys) + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .notice(notice)) }
        return closing + told + changed(now: now)
    }

    /// Revokes one credential: an observer's, or a member's (which also takes them off the roster).
    public mutating func revoke(credential id: Data, now: Date) -> [Outgoing] {
        guard let record = credentials.first(where: { $0.id == id && !$0.revoked }) else { return [] }
        if let member = record.member { return removeMember(member, now: now) }
        return revoke([id])
    }

    private mutating func revoke(_ ids: Set<Data>) -> [Outgoing] {
        for i in credentials.indices where ids.contains(credentials[i].id) { credentials[i].revoked = true }
        let gone = links.compactMap { peer, auth -> PeerID? in
            if case let .member(id) = auth, ids.contains(id) { return peer }
            return nil
        }.sorted { $0.raw < $1.raw }
        for peer in gone {
            peers[peer] = nil
            observers.remove(peer)
            links[peer] = nil
        }
        return gone.map { Outgoing(to: $0, .refused("Removed from the squad."), thenClose: true) }
    }

    /// The real reset: a new root key, so every credential stops working, and an empty roster.
    /// Everyone joins again with a new invite. The identity key stays, so this is still the same
    /// leader to anyone who pinned it.
    public mutating func resetSquad(root: Data = .random(32), now: Date) -> [Outgoing] {
        let everyone = links.keys.sorted { $0.raw < $1.raw }
        keys.root = root
        epoch += 1
        credentials = []
        squad.members = []
        positions = [:]
        peers = [:]
        observers = []
        links = [:]
        closeJoining()
        revision += 1
        return everyone.map { Outgoing(to: $0, .refused("The squad was reset. Join again."), thenClose: true) }
    }

    /// Moves this device to a new identity key, signed by the old one so that devices which
    /// pinned the old key follow. Devices that are away get the change when they next connect.
    public mutating func changeIdentity(to new: LeaderKeys, now: Date) -> [Outgoing] {
        let change = LeaderKeyChange(squad: squadID, to: new.publicKey, time: now, signedBy: keys)
        keys.identity = new.identity
        keyChanges.append(change)
        closeJoining()   // open invites name the old key
        return (Array(peers.keys) + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .leaderKey(change)) }
    }

    /// The leader's own position, shared with observers like a member's. The leader's device is
    /// on the roster only if the app puts it there.
    public mutating func setPosition(_ position: MemberPosition, of member: MemberID) -> [Outgoing] {
        guard squad.members.contains(where: { $0.id == member }) else { return [] }
        var p = position
        p.member = member
        positions[member] = p
        return report(p, except: nil)
    }

    /// A new position, to everyone who sees positions except the link it came from.
    private func report(_ p: MemberPosition, except sender: PeerID?) -> [Outgoing] {
        let members = sharesPositions ? peers.keys.filter { $0 != sender } : []
        return (Array(observers) + members).sorted { $0.raw < $1.raw }
            .map { Outgoing(to: $0, .positions(PositionsReport(squad: squadID, positions: [p]))) }
    }

    /// Sends an order to some members (`to`), or to the whole squad (nil). Observers see it too.
    public mutating func sendOrder(_ kind: Order.Kind, text: String, at: GeoPoint? = nil, to: [MemberID]? = nil,
                                   now: Date) -> [Outgoing] {
        let roster = Set(squad.members.map(\.id))
        let targets = to.map { $0.filter(roster.contains) }
        if let targets, targets.isEmpty { return problem("Pick at least one member.") }
        let order = Order(kind: kind, text: text, at: at, to: targets, time: now)
        orders.append(order)
        if orders.count > Self.maxOrdersKept { orders.removeFirst(orders.count - Self.maxOrdersKept) }
        let members = peers.filter { order.isFor($0.value) }.map(\.key)
        return (members + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .order(order)) }
    }

    /// A note from the leader's own device, to everyone who gets notes.
    public mutating func postNote(_ note: FieldNote) -> [Outgoing] {
        notes.append(note)
        if notes.count > Self.maxNotesKept { notes.removeFirst(notes.count - Self.maxNotesKept) }
        return passOn(note, except: nil)
    }

    /// A note to observers, and to the other members when the squad shares notes.
    private func passOn(_ note: FieldNote, except sender: PeerID?) -> [Outgoing] {
        let members = sharesNotes ? peers.keys.filter { $0 != sender } : []
        return (members + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .note(note)) }
    }

    /// Takes an order back: everyone it was for, and observers, are told it no longer needs
    /// doing. Answers that arrive after this are ignored. A member who is away hears when they
    /// are back.
    public mutating func cancelOrder(_ id: UUID, now: Date) -> [Outgoing] {
        guard let order = orders.first(where: { $0.id == id }), !cancelled.contains(id) else { return [] }
        cancelled.insert(id)
        let members = peers.filter { order.isFor($0.value) }.map(\.key)
        return (members + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .orderCancel(id)) }
    }

    /// Who an order is for, by member.
    public func recipients(of order: Order) -> [Member] {
        squad.members.filter { order.isFor($0.id) }
    }

    /// Check fire called on this device.
    public mutating func callCheckFire(by: String, now: Date) -> [Outgoing] {
        raiseCheckFire(CheckFire(by: by), now: now)
    }

    /// Lifts check fire. A mission may keep its own holds up after this.
    public mutating func withdrawCheckFire(now: Date) -> [Outgoing] {
        guard activeCheckFire != nil else { return [] }
        activeCheckFire = nil
        return changed(now: now)
    }

    // MARK: Running the mission

    /// Runs one of the mission's actions with the core's view, then sends what it asks for.
    public mutating func run(_ now: Date, _ action: (inout M, CoreView) -> MissionStep) -> [Outgoing] {
        let core = view
        let step = action(&mission, core)
        return finish(step, now: now)
    }

    private mutating func finish(_ step: MissionStep, now: Date) -> [Outgoing] {
        if step.clearsProblem { lastProblem = nil }
        if let p = step.problem { lastProblem = p }
        if step.changed { return step.out + changed(now: now) }
        if step.statusOnly { return step.out + statusToEveryone(now: now) }
        return step.out
    }

    // MARK: Internals

    private mutating func raiseCheckFire(_ cf: CheckFire, now: Date) -> [Outgoing] {
        guard !seenCheckFires.contains(cf.id) else { return [] }
        seenCheckFires.insert(cf.id)
        if activeCheckFire == nil { activeCheckFire = cf }
        mission.checkFireRaised(core: view)
        return changed(now: now)
    }

    private mutating func problem(_ text: String) -> [Outgoing] {
        lastProblem = text
        return []
    }

    /// Bumps the revision and tells everyone.
    private mutating func changed(now: Date) -> [Outgoing] {
        revision += 1
        return statusToEveryone(now: now)
    }

    /// Status to every member and observer.
    private func statusToEveryone(now: Date) -> [Outgoing] {
        let s = status(now: now)
        return (Array(peers.keys) + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .status(s)) }
    }

    /// What members see: the roster, the holds and the mission's part.
    public func status(now: Date) -> SquadStatus {
        let core = view
        let section = mission.status(core: core, now: now).map { MissionStatus(id: M.id, version: M.version, payload: $0) }
        return SquadStatus(revision: revision, squad: squad,
                           holds: holds(now: now).sorted { ($0.source, $0.kind, $0.text) < ($1.source, $1.kind, $1.text) },
                           missions: section.map { [$0] } ?? [])
    }
}
