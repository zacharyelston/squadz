import Foundation
import Network
import Observation
import SquadKit
import SquadLink

/// A member and where they were last seen, for the map and the list.
struct Located: Identifiable, Equatable {
    var member: Member
    var position: MemberPosition?
    var isMe: Bool
    var isLeader: Bool
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
}

/// The whole app: this phone either leads one squad, is a member of one, or is in none.
///
/// A leader's phone *is* the squad: it holds the roster and everyone's positions and the others
/// connect to it directly, over Wi-Fi or a mesh. There is no server.
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

    let device: UUID
    private let defaults: UserDefaults
    private let keychain: SquadKeychain
    private let folder: URL
    private let service: SquadService
    private let location = LocationTracker()
    private var ticker: Task<Void, Never>?

    private var core: SquadCore<NoMission>?
    private var host: SquadLinkHost?
    private var client: SquadLinkClient?
    private var enroller: SquadEnroller?
    /// For tests: where a member connects instead of looking the leader up with Bonjour.
    var fixedEndpoint: (() -> NWEndpoint?)?

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

    // MARK: Who's where

    var located: [Located] {
        (squad?.members ?? []).map {
            Located(member: $0, position: positions[$0.id], isMe: $0.id == me, isLeader: $0.id == leaderID)
        }
    }

    // MARK: Launch

    /// Picks up where the app left off: leading a squad, or a member of one.
    func resume() {
        guard role == .none else { return }
        if let saved = loadLeader(), let keys = try? keychain.leaderKeys(for: saved.squad.id) {
            lead(SquadCore(squad: saved.squad, mission: NoMission(), keys: keys, credentials: saved.credentials,
                           epoch: saved.epoch, keyChanges: saved.keyChanges, revision: saved.revision, sharesPositions: true),
                 me: saved.me)
        } else if let id = defaults.string(forKey: "memberSquad").flatMap(UUID.init(uuidString:)),
                  let credential = try? keychain.credential(for: SquadID(id)) {
            connect(credential)
        }
    }

    /// The app came back to the front: links that dropped while it was away come back now.
    func foreground() {
        host?.restart()
        client?.retryNow()
    }

    // MARK: Leading

    func startSquad(name squadName: String, as myName: String) {
        guard role == .none else { return }
        let mine = Member(name: myName, device: device)
        let core = SquadCore(squad: Squad(name: squadName, members: [mine]), mission: NoMission(), sharesPositions: true)
        do {
            try keychain.save(core.keys, for: core.squadID)
        } catch {
            alert = "Couldn't save this squad's keys, so it wasn't started."
            return
        }
        lead(core, me: mine.id)
    }

    private func lead(_ core: SquadCore<NoMission>, me: MemberID) {
        do {
            let host = try SquadLinkHost(name: core.squad.name, keys: core.linkKeys(now: .now), service: service,
                                         txt: [SquadService.Key.tag: core.squadID.tag], advertise: advertise)
            host.onOpened = { [weak self] peer, identity in
                MainActor.assumeIsolated { self?.core?.linkOpened(peer, identity: identity) }
            }
            host.onMessage = { [weak self] message, peer in
                MainActor.assumeIsolated {
                    guard let self, let out = self.core?.handle(message, from: peer, now: .now) else { return }
                    self.sent(out)
                }
            }
            host.onPeerClosed = { [weak self] peer in MainActor.assumeIsolated { self?.core?.peerClosed(peer) } }
            host.onFailed = { [weak self] _ in MainActor.assumeIsolated { self?.linkProblem = "Restarting the squad's link…" } }
            host.onReady = { [weak self] _ in MainActor.assumeIsolated { self?.linkProblem = nil } }
            self.core = core
            self.host = host
            self.me = me
            leaderID = me
            role = .leader
            host.start()
            sent([])
            startReporting()
        } catch {
            alert = "Couldn't start the squad's link: \(error.localizedDescription)"
        }
    }

    /// After anything the core did: send what it asked, tell the link who may connect now, show
    /// the new state, and save it.
    private func sent(_ out: [Outgoing]) {
        guard let core, let host else { return }
        host.send(out)
        host.setKeys(core.linkKeys(now: .now))
        squad = core.squad
        positions = core.positions
        if let invite, invite.isExpired(now: .now) || !core.invitations.contains(where: { $0.secret == invite.enrol }) {
            self.invite = nil
        }
        saveLeader()
    }

    /// Opens joining and returns the invite to show. Anyone who scans it before it expires joins.
    func openJoining() {
        guard var core else { return }
        core.closeJoining()
        invite = core.openJoining(now: .now, by: squad?.members.first { $0.id == me }?.name)
        self.core = core
        sent([])
    }

    func closeJoining() {
        core?.closeJoining()
        invite = nil
        sent([])
    }

    func remove(_ member: MemberID) {
        guard member != me, let out = core?.removeMember(member, now: .now) else { return }
        sent(out)
    }

    /// Ends the squad: everyone is cut off and nothing of it is kept.
    func endSquad() {
        guard role == .leader, let id = core?.squadID else { return }
        if let out = core?.resetSquad(now: .now) { host?.send(out) }
        // Let the goodbyes go before the link closes.
        let host = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { host?.stop() }
        try? keychain.removeLeaderKeys(for: id)
        try? FileManager.default.removeItem(at: leaderFile)
        clear()
    }

    private var leaderFile: URL { folder.appendingPathComponent("leading.json") }

    private func saveLeader() {
        guard let core, let me else { return }
        let saved = LeaderSaved(squad: core.squad, me: me, credentials: core.credentials, epoch: core.epoch,
                                keyChanges: core.keyChanges, revision: core.revision)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: leaderFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
            report()
        case .searching, .connecting:
            linkProblem = "Looking for \(squad?.name ?? "the squad")…"
        case .reconnecting:
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
        client?.stop()
        forgetMembership(of: id)
    }

    private func forgetMembership(of id: SquadID) {
        try? keychain.removeCredential(for: id)
        defaults.removeObject(forKey: "memberSquad")
        clear()
    }

    private func clear() {
        ticker?.cancel()
        ticker = nil
        location.stop()
        client = nil
        host = nil
        core = nil
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
        location.start()
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
        guard let me, let position = location.latest() else { return }
        setMyPosition(position, member: me)
    }

    /// Also the way tests place this phone.
    func setMyPosition(_ position: MemberPosition, member me: MemberID) {
        var mine = position
        mine.member = me
        positions[me] = mine
        switch role {
        case .leader:
            if let out = core?.setPosition(position, of: me) { sent(out) }
        case .member:
            client?.send(.position(position))
        case .none:
            break
        }
    }
}
