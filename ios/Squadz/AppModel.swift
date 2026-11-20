import CoreGeo
import Foundation
import Network
import Observation
import SquadKit
import SquadLink

/// How a member's device is linked to the leader's, as the leader's device sees it.
enum MemberLink: Equatable {
    case direct
    case relay
    case away
}

/// A member and where they were last seen, for the map and the list.
struct Located: Identifiable, Equatable {
    var member: Member
    var position: MemberPosition?
    var isMe: Bool
    var isLeader: Bool
    /// Known only on the leader's device, and not for the leader.
    var link: MemberLink? = nil
    /// When they joined. Known only on the leader's device.
    var joined: Date? = nil
    var id: MemberID { member.id }

    /// A position older than this is shown dimmed.
    static let staleAfter: TimeInterval = 120

    func age(now: Date) -> TimeInterval? { position.map { max(0, now.timeIntervalSince($0.time)) } }
    func isStale(now: Date) -> Bool { age(now: now).map { $0 > Self.staleAfter } ?? true }
}

/// What the leader's device saves between launches. No secrets: its keys are in the Keychain.
struct LeaderSaved: Codable, Equatable {
    var squad: Squad
    var me: MemberID
    var credentials: [CredentialRecord]
    var epoch: Int
    var keyChanges: [LeaderKeyChange]
    var revision: Int
    /// The relay this squad was started with, if any.
    var relay: RelayAddress?
}

/// The whole app: this phone either leads one squad, is a member of one, or is in none.
///
/// A leader's phone *is* the squad: it holds the roster and everyone's positions and the others
/// connect to it directly, over Wi-Fi or a mesh. There is no server. A squad started with a relay
/// can also be reached over the internet: the relay passes the same links along and decides nothing.
@MainActor
@Observable
final class AppModel {
    enum Role: Equatable { case none, leader, member }

    private(set) var role: Role = .none
    private(set) var squad: Squad?
    private(set) var me: MemberID?
    private(set) var leaderID: MemberID?
    private(set) var positions: [MemberID: MemberPosition] = [:]
    /// Why the squad isn't up to date, for a banner.
    private(set) var linkProblem: String?
    /// An invite that was scanned or opened and is waiting for a yes.
    var offered: SquadInvite?
    private(set) var joining = false
    var alert: String?
    /// The leader's open invite, to show as a QR code.
    private(set) var invite: SquadInvite?
    /// How the relay is doing, for a line under the title. Nil for a squad without one.
    private(set) var relayNote: String?
    /// The latest thing the squad was told, like "Ana left the squad." Shown for a short while.
    private(set) var notice: Notice?

    /// On the leader's device: the orders it sent, newest first. On a member's phone: the orders
    /// that are for it, newest first.
    private(set) var orders: [Order] = []
    /// On the leader's device: each recipient's latest answer to each order.
    private(set) var answers: [UUID: [MemberID: OrderAck.Response]] = [:]
    /// On a member's phone: what it answered.
    private(set) var myAnswers: [UUID: OrderAck.Response] = [:]

    let device: UUID
    private let defaults: UserDefaults
    private let keychain: SquadKeychain
    private let folder: URL
    private let service: SquadService
    private let location = LocationTracker()
    private var ticker: Task<Void, Never>?

    private var core: SquadCore<NoMission>?
    private var lastSaved: LeaderSaved?
    private var host: SquadLinkHost?
    private var relayHost: RelayLinkHost?
    private var client: SquadLinkClient?
    private var enroller: SquadEnroller?
    /// For tests: where a member connects instead of looking the leader up with Bonjour.
    var fixedEndpoint: (() -> NWEndpoint?)?
    /// Seconds a member looks for the squad on this network before going through its relay.
    var relayAfter: TimeInterval = 3

    /// Seconds between position reports.
    static let reportEvery: TimeInterval = 10

    init(defaults: UserDefaults = .standard, keychainService: String = "com.zacelston.squadz.squads",
         folder: URL = URL.applicationSupportDirectory, service: SquadService = .squadz, advertise: Bool = true) {
        self.defaults = defaults
        keychain = SquadKeychain(service: keychainService)
        self.folder = folder
        self.service = service
        self.advertise = advertise
        if let saved = defaults.string(forKey: "device").flatMap(UUID.init(uuidString:)) {
            device = saved
        } else {
            device = UUID()
            defaults.set(device.uuidString, forKey: "device")
        }
    }

    private let advertise: Bool
    var hostPort: UInt16? { host?.port }
    var hostIsListening: Bool { host?.isListening == true }

    // MARK: Who's where

    var located: [Located] {
        (squad?.members ?? []).map { m in
            let others = role == .leader && m.id != me
            return Located(member: m, position: positions[m.id], isMe: m.id == me, isLeader: m.id == leaderID,
                           link: others ? (links[m.id] ?? .away) : nil,
                           joined: others ? core?.credentials.first { $0.member == m.id && !$0.revoked }?.issued : nil)
        }
    }

    /// On the leader's device: which members are linked right now, and how.
    private var links: [MemberID: MemberLink] = [:]

    private func refreshLinks() {
        var now: [MemberID: MemberLink] = [:]
        for (peer, member) in core?.peers ?? [:] {
            now[member] = relayHost?.connections[peer] != nil ? .relay : .direct
        }
        if now != links { links = now }
    }

    // MARK: Launch

    /// Picks up where the app left off: leading a squad, or a member of one.
    func resume() {
        guard role == .none else { return }
        if let saved = loadLeader(), let keys = try? keychain.leaderKeys(for: saved.squad.id) {
            lead(SquadCore(squad: saved.squad, mission: NoMission(), keys: keys, credentials: saved.credentials,
                           epoch: saved.epoch, keyChanges: saved.keyChanges, revision: saved.revision, sharesPositions: true),
                 me: saved.me, relay: saved.relay)
        } else if let id = defaults.string(forKey: "memberSquad").flatMap(UUID.init(uuidString:)),
                  let credential = try? keychain.credential(for: SquadID(id)) {
            connect(credential)
        }
    }

    /// The app came back to the front: links that dropped while it was away come back now.
    func foreground() {
        host?.restart()
        relayHost?.retryNow()
        client?.retryNow()
    }

    // MARK: Leading

    /// The relay new squads are started with, as typed on the home screen. Nil for none.
    /// Throws nothing: a relay that doesn't read as an address is reported by `startSquad`.
    private var relaySetting: (text: String, address: RelayAddress?) {
        let text = (defaults.string(forKey: "relayURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, RelayAddress(text: text, pin: defaults.string(forKey: "relayPin")))
    }

    func startSquad(name squadName: String, as myName: String) {
        guard role == .none else { return }
        let relay = relaySetting
        guard relay.text.isEmpty || relay.address != nil else {
            alert = "The relay's address or certificate fingerprint doesn't look right. Fix it or clear it, then start the squad."
            return
        }
        let mine = Member(name: myName, device: device)
        let core = SquadCore(squad: Squad(name: squadName, members: [mine]), mission: NoMission(), sharesPositions: true)
        do {
            try keychain.save(core.keys, for: core.squadID)
        } catch {
            alert = "Couldn't save this squad's keys, so it wasn't started."
            return
        }
        lead(core, me: mine.id, relay: relay.address)
        if role != .leader { try? keychain.removeLeaderKeys(for: core.squadID) }
    }

    private func lead(_ core: SquadCore<NoMission>, me: MemberID, relay: RelayAddress?) {
        do {
            let host = try SquadLinkHost(name: core.squad.name, keys: core.linkKeys(now: .now), service: service,
                                         txt: [SquadService.Key.tag: core.squadID.tag], advertise: advertise)
            host.onOpened = { [weak self] peer, identity in
                MainActor.assumeIsolated { self?.core?.linkOpened(peer, identity: identity) }
            }
            host.onMessage = { [weak self] message, peer in
                MainActor.assumeIsolated {
                    self?.updateLeader { $0.handle(message, from: peer, now: .now) }
                }
            }
            host.onPeerClosed = { [weak self] peer in MainActor.assumeIsolated { self?.core?.peerClosed(peer); self?.refreshLinks() } }
            host.onFailed = { [weak self] _ in MainActor.assumeIsolated { self?.linkProblem = "Restarting the squad's link…" } }
            host.onReady = { [weak self] _ in MainActor.assumeIsolated { self?.linkProblem = nil } }
            do {
                try saveLeader(core, me: me, relay: relay)
            } catch {
                alert = "Couldn't save this squad on this phone. Check available storage and try again."
                return
            }
            self.core = core
            self.host = host
            self.me = me
            leaderID = me
            role = .leader
            leadingRelay = relay
            host.start()
            if let relay { openRoom(on: relay, for: core) }
            sent([])
            startReporting()
        } catch {
            alert = "Couldn't start the squad's link: \(error.localizedDescription)"
        }
    }

    private var leadingRelay: RelayAddress?

    /// The squad's room on its relay. Members' links arrive through it exactly as they do from
    /// the local network, and the core treats them the same.
    private func openRoom(on relay: RelayAddress, for core: SquadCore<NoMission>) {
        let id = core.squadID
        let room = RelayLinkHost(address: relay, squad: id, token: try? keychain.relayToken(for: id),
                                 keys: core.linkKeys(now: .now), invites: core.relayInvites(now: .now))
        room.onOpened = { [weak self] peer, identity in
            MainActor.assumeIsolated { self?.core?.linkOpened(peer, identity: identity) }
        }
        room.onMessage = { [weak self] message, peer in
            MainActor.assumeIsolated {
                self?.updateLeader { $0.handle(message, from: peer, now: .now) }
            }
        }
        room.onPeerClosed = { [weak self] peer in MainActor.assumeIsolated { self?.core?.peerClosed(peer); self?.refreshLinks() } }
        room.onToken = { [weak self] token in MainActor.assumeIsolated { try? self?.keychain.save(relayToken: token, for: id) } }
        room.onStatus = { [weak self] status in
            MainActor.assumeIsolated {
                switch status {
                case .connecting: self?.relayNote = "Relay: connecting…"
                case .open: self?.relayNote = "Relay: open"
                case .retrying: self?.relayNote = "Relay: can't reach it. Trying again…"
                case let .stopped(why): self?.relayNote = "Relay: off. \(why)"
                }
            }
        }
        relayHost = room
        relayNote = "Relay: connecting…"
        room.start()
    }

    /// A reply can hand a member their credential. Keep the state it depends on
    /// before sending it or installing the new link keys.
    private func updateLeader(_ change: (inout SquadCore<NoMission>) -> [Outgoing]) {
        guard var next = core, let me else { return }
        let out = change(&next)
        do {
            try saveLeader(next, me: me, relay: leadingRelay)
        } catch {
            for reply in out {
                if case .enrolled = reply.body {
                    let refusal = [Outgoing(to: reply.to, .refused("The leader couldn't save your membership. Try joining again."), thenClose: true)]
                    host?.send(refusal)
                    relayHost?.send(refusal)
                }
            }
            alert = "Couldn't save the squad change. Check available storage and try again."
            return
        }
        core = next
        sent(out)
    }

    private func sent(_ out: [Outgoing]) {
        guard let core, let host else { return }
        host.send(out)
        host.setKeys(core.linkKeys(now: .now))
        relayHost?.send(out)
        relayHost?.setKeys(core.linkKeys(now: .now), invites: core.relayInvites(now: .now))
        squad = core.squad
        positions = core.positions
        orders = core.orders.reversed()
        answers = core.acks
        refreshLinks()
        if let latest = core.notices.last {
            tell(latest)
        }
        if let invite, invite.isExpired(now: .now) || !core.invitations.contains(where: { $0.secret == invite.enrol }) {
            self.invite = nil
        }
    }

    /// Opens joining and returns the invite to show. Anyone who scans it before it expires joins.
    func openJoining() {
        guard var core else { return }
        core.closeJoining()
        invite = core.openJoining(now: .now, by: squad?.members.first { $0.id == me }?.name)
        // The invite names the relay only once the relay has a room for this squad.
        if let relayHost, relayHost.hasRoom { invite?.relay = relayHost.address }
        self.core = core
        sent([])
    }

    func closeJoining() {
        core?.closeJoining()
        invite = nil
        sent([])
    }

    func remove(_ member: MemberID) {
        guard member != me else { return }
        updateLeader { $0.removeMember(member, now: .now) }
    }

    // MARK: Orders

    /// Sends an order to some members, or to everyone if `to` is empty. A move-to order needs a
    /// place. False if it wasn't sent.
    @discardableResult
    func sendOrder(_ kind: Order.Kind, text: String, at place: GeoPoint? = nil, to: Set<MemberID> = []) -> Bool {
        guard role == .leader, kind != .moveTo || place != nil else { return false }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .note || !words.isEmpty else { return false }
        let before = core?.orders.count ?? 0
        updateLeader { $0.sendOrder(kind, text: words, at: place, to: to.isEmpty ? nil : Array(to), now: .now) }
        return (core?.orders.count ?? 0) > before
    }

    /// Who an order is for, without the leader, who gave it.
    func recipients(of order: Order) -> [Member] {
        (squad?.members ?? []).filter { order.isFor($0.id) && $0.id != leaderID }
    }

    /// True once everyone an order is for has answered done or can't, or has left.
    func isSettled(_ order: Order) -> Bool {
        switch role {
        case .leader:
            return recipients(of: order).allSatisfy { m in
                let a = answers[order.id]?[m.id]
                return a == .done || a == .cannot
            }
        case .member:
            let a = myAnswers[order.id]
            return a == .done || a == .cannot
        case .none:
            return true
        }
    }

    /// Orders still to be carried out, newest first: for the map, and for a member's card.
    var openOrders: [Order] { orders.filter { !isSettled($0) } }

    /// The same orders in the order they came, oldest first: what to do next is first.
    var queue: [Order] { openOrders.reversed() }

    /// A member's answer to an order.
    func answer(_ order: Order, _ response: OrderAck.Response) {
        guard role == .member, orders.contains(where: { $0.id == order.id }) else { return }
        myAnswers[order.id] = response
        client?.send(.orderAck(OrderAck(order: order.id, response: response)))
    }

    /// Ends the squad: everyone is cut off and nothing of it is kept.
    func endSquad() {
        guard role == .leader, let id = core?.squadID else { return }
        if let out = core?.resetSquad(now: .now) {
            host?.send(out)
            relayHost?.send(out)
        }
        // Let the goodbyes go before the links close. The relay forgets the squad too.
        let host = host, relayHost = relayHost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host?.stop()
            relayHost?.stop(endSquad: true)
        }
        try? keychain.removeLeaderKeys(for: id)
        try? keychain.removeRelayToken(for: id)
        try? FileManager.default.removeItem(at: leaderFile)
        clear()
    }

    private var leaderFile: URL { folder.appendingPathComponent("leading.json") }

    private func saveLeader(_ core: SquadCore<NoMission>, me: MemberID, relay: RelayAddress?) throws {
        let saved = LeaderSaved(squad: core.squad, me: me, credentials: core.credentials, epoch: core.epoch,
                                keyChanges: core.keyChanges, revision: core.revision, relay: relay)
        guard saved != lastSaved else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: leaderFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastSaved = saved
    }

    private func loadLeader() -> LeaderSaved? {
        (try? Data(contentsOf: leaderFile)).flatMap { try? JSONDecoder().decode(LeaderSaved.self, from: $0) }
    }

    // MARK: Joining

    /// A scanned code or an opened link. It only offers: joining takes a tap on `join`.
    func offer(_ text: String) {
        guard role == .none, !joining else {
            alert = role == .none ? nil : "Leave this squad before joining another."
            return
        }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let invite = try? SquadInvite(url: url, scheme: service.scheme) else {
            alert = "That isn't a Squadz invite."
            return
        }
        guard !invite.isExpired(now: .now) else {
            alert = "This invite has expired. Ask for a new one."
            return
        }
        offered = invite
    }

    func join(_ invite: SquadInvite, as name: String) {
        guard role == .none, !joining else { return }
        offered = nil
        joining = true
        let enroller = SquadEnroller(invite: invite, name: name, device: device, service: service)
        enroller.fixedEndpoint = fixedEndpoint?()
        enroller.relayAfter = relayAfter
        enroller.onDone = { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.joining = false
                self.enroller = nil
                switch result {
                case let .success(credential):
                    do {
                        try self.keychain.save(credential)
                    } catch {
                        self.alert = "Joined, but couldn't keep the squad's key on this phone. Ask for a new invite."
                        return
                    }
                    self.defaults.set(credential.squad.raw.uuidString, forKey: "memberSquad")
                    self.connect(credential)
                case let .failure(why):
                    self.alert = why.reason
                }
            }
        }
        self.enroller = enroller
        enroller.start()
    }

    // MARK: A member

    private func connect(_ credential: MemberCredential) {
        let name = defaults.string(forKey: "displayName") ?? ""
        let client = SquadLinkClient(credential: credential, name: name, device: device, service: service)
        client.fixedEndpoint = fixedEndpoint?()
        client.relayAfter = relayAfter
        client.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.received(message.body) } }
        client.onStatus = { [weak self] status in MainActor.assumeIsolated { self?.linkChanged(status, squad: credential.squad) } }
        client.onCredentialChanged = { [weak self] new in MainActor.assumeIsolated { try? self?.keychain.save(new) } }
        self.client = client
        me = credential.member
        squad = Squad(id: credential.squad, name: credential.squadName)
        role = .member
        linkProblem = "Looking for \(credential.squadName)…"
        client.start()
        startReporting()
    }

    private func received(_ body: SquadMessage.Body) {
        switch body {
        case let .welcome(w):
            me = w.member
            show(w.squad)
        case let .status(s):
            show(s.squad)
        case let .positions(report):
            for p in report.positions { if let m = p.member { positions[m] = p } }
        case let .notice(n):
            if let m = n.member { positions[m] = nil }
            tell(n)
        case let .order(o):
            // The leader's device sends an order again when this phone reconnects, until it is
            // answered done or can't.
            guard let me, o.isFor(me), !orders.contains(where: { $0.id == o.id }) else { break }
            orders.insert(o, at: 0)
            orders.sort { $0.time > $1.time }
        default:
            break
        }
    }

    private func show(_ new: Squad) {
        squad = new
        // The leader put itself first on the roster when it started the squad.
        leaderID = new.members.first?.id
        let roster = Set(new.members.map(\.id))
        positions = positions.filter { roster.contains($0.key) }
    }

    private func linkChanged(_ status: SquadLinkClient.Status, squad id: SquadID) {
        switch status {
        case .connected:
            linkProblem = nil
            relayNote = client?.isRelayed == true ? "Connected through the relay" : nil
            report()
        case .searching, .connecting:
            relayNote = nil
            linkProblem = "Looking for \(squad?.name ?? "the squad")…"
        case .reconnecting:
            relayNote = nil
            linkProblem = "Lost the link to \(squad?.name ?? "the squad"). Trying again…"
        case let .stopped(why):
            guard role == .member, why != "Left" else { return }
            // The leader won't have this phone back: forget the squad.
            forgetMembership(of: id)
            alert = why
        }
    }

    func leaveSquad() {
        guard role == .member, let id = squad?.id else { return }
        // For good: the leader's device takes this phone off the squad and tells the others.
        client?.stop(forGood: true)
        forgetMembership(of: id)
    }

    private func forgetMembership(of id: SquadID) {
        try? keychain.removeCredential(for: id)
        defaults.removeObject(forKey: "memberSquad")
        clear()
    }

    private var shownNotice: UUID?

    /// Shows a notice for a quarter of a minute.
    private func tell(_ n: Notice) {
        guard n.id != shownNotice else { return }
        shownNotice = n.id
        notice = n
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if self?.notice?.id == n.id { self?.notice = nil }
        }
    }

    private func clear() {
        notice = nil
        orders = []
        answers = [:]
        myAnswers = [:]
        links = [:]
        ticker?.cancel()
        ticker = nil
        location.stop()
        client = nil
        host = nil
        relayHost = nil
        leadingRelay = nil
        relayNote = nil
        core = nil
        lastSaved = nil
        role = .none
        squad = nil
        me = nil
        leaderID = nil
        positions = [:]
        linkProblem = nil
        invite = nil
    }

    // MARK: Positions

    private func startReporting() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.report()
                try? await Task.sleep(for: .seconds(Self.reportEvery))
            }
        }
    }

    /// This phone's position, to the squad.
    private func report() {
        guard let me else { return }
        location.start()
        guard let position = location.latest() else { return }
        setMyPosition(position, member: me)
    }

    /// Also the way tests place this phone.
    func setMyPosition(_ position: MemberPosition, member me: MemberID) {
        var mine = position
        mine.member = me
        switch role {
        case .leader:
            updateLeader { $0.setPosition(position, of: me) }
        case .member:
            positions[me] = mine
            client?.send(.position(position))
        case .none:
            break
        }
    }
}
