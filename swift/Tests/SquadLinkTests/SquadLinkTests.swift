import Foundation
import Network
import XCTest
import SquadKit
@testable import SquadLink

/// Real sockets on this Mac: a leader's host wired to a SquadCore the way an app wires it, and
/// phones that join by invite and link by credential.
final class SquadLinkTests: XCTestCase {
    let queue = DispatchQueue(label: "squad-link-test")

    /// A leader on a loopback port. Everything it does happens on `queue`.
    final class Leader {
        var core: SquadCore<NoMission>
        let host: SquadLinkHost
        let queue: DispatchQueue

        init(core: SquadCore<NoMission> = SquadCore(squad: Squad(name: "Red"), mission: NoMission()),
             service: SquadService = .squadz, queue: DispatchQueue) throws {
            self.core = core
            self.queue = queue
            host = try SquadLinkHost(name: "Red", keys: [], service: service, advertise: false, queue: queue)
            host.onOpened = { [unowned self] peer, identity in self.core.linkOpened(peer, identity: identity) }
            host.onMessage = { [unowned self] m, peer in self.send(self.core.handle(m, from: peer, now: Date())) }
            host.onPeerClosed = { [unowned self] peer in self.core.peerClosed(peer) }
        }

        /// Sends what the core returned, then gives the transport the keys that may connect now.
        func send(_ out: [Outgoing]) {
            host.send(out)
            host.setKeys(core.linkKeys(now: Date()))
        }

        /// One of the leader's own actions. Returns once the listener is taking the new keys.
        func act<T>(_ action: (inout SquadCore<NoMission>) -> T) -> T {
            let result = queue.sync { () -> T in
                let result = action(&core)
                host.setKeys(core.linkKeys(now: Date()))
                return result
            }
            settle()
            return result
        }

        func settle() {
            for _ in 0..<500 where !queue.sync(execute: { host.isListening }) { Thread.sleep(forTimeInterval: 0.01) }
        }

        func command(_ action: (inout SquadCore<NoMission>) -> [Outgoing]) {
            queue.sync { send(action(&core)) }
        }

        var endpoint: NWEndpoint { settle(); return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port!)!) }
    }

    private func startLeader(_ leader: Leader) {
        let ready = expectation(description: "listening")
        ready.assertForOverFulfill = false   // it reports ready again after each restart
        leader.host.onReady = { _ in ready.fulfill() }
        leader.host.start()
        wait(for: [ready], timeout: 5)
    }

    private func leader(service: SquadService = .squadz) throws -> Leader {
        let l = try Leader(service: service, queue: queue)
        startLeader(l)
        addTeardownBlock { [queue] in queue.sync { l.host.stop() } }
        return l
    }

    private func enrol(_ enroller: SquadEnroller, at endpoint: NWEndpoint, now: Date = Date(),
                       timeout: TimeInterval = 10) -> Result<MemberCredential, SquadLinkFailure> {
        enroller.fixedEndpoint = endpoint
        let done = expectation(description: "enrolment answered")
        var result: Result<MemberCredential, SquadLinkFailure> = .failure(SquadLinkFailure("no answer"))
        enroller.onDone = { result = $0; done.fulfill() }
        queue.sync { enroller.start(now: now) }
        wait(for: [done], timeout: timeout)
        return result
    }

    /// Joins as a person would: the invite goes through its link form, as a scanned QR code does.
    private func join(_ leader: Leader, name: String, device: UUID = UUID()) throws -> MemberCredential {
        let shown = leader.act { $0.openJoining(now: Date(), by: "Leader's iPad") }.url(scheme: SquadService.squadz.scheme)
        let scanned = try SquadInvite(url: shown, scheme: SquadService.squadz.scheme)
        let credential = try enrol(SquadEnroller(invite: scanned, name: name, device: device, queue: queue), at: leader.endpoint).get()
        leader.settle()
        return credential
    }

    private func client(_ credential: MemberCredential, name: String, at leader: Leader) -> SquadLinkClient {
        let c = SquadLinkClient(credential: credential, name: name, device: UUID(), queue: queue)
        c.fixedEndpoint = leader.endpoint
        c.baseDelay = 0.2
        addTeardownBlock { [queue] in queue.sync { c.stop() } }
        return c
    }

    private func waitForStop(_ client: SquadLinkClient, timeout: TimeInterval = 15) -> String {
        let stopped = expectation(description: "stopped")
        stopped.assertForOverFulfill = false
        var why = ""
        queue.sync {
            if case let .stopped(w) = client.status { why = w; stopped.fulfill() }
            client.onStatus = { s in if case let .stopped(w) = s { why = w; stopped.fulfill() } }
        }
        wait(for: [stopped], timeout: timeout)
        return why
    }

    // MARK: Joining

    func testJoinByScannedInviteThenLinkByCredential() throws {
        let leader = try leader()
        let credential = try join(leader, name: "Ana")
        XCTAssertEqual(credential.squadName, "Red")
        XCTAssertEqual(credential.leader, leader.act { $0.keys.publicKey })

        let phone = client(credential, name: "Ana", at: leader)
        let welcomed = expectation(description: "welcome")
        let status = expectation(description: "status")
        status.assertForOverFulfill = false
        phone.onMessage = { m in
            switch m.body {
            case let .welcome(w):
                XCTAssertEqual(w.member, credential.member)
                XCTAssertEqual(w.squad.members.map(\.name), ["Ana"])
                welcomed.fulfill()
            case .status: status.fulfill()
            default: break
            }
        }
        phone.start()
        wait(for: [welcomed, status], timeout: 10)
        XCTAssertEqual(leader.act { $0.peers.count }, 1)
    }

    func testAnExpiredInviteIsRefused() throws {
        let leader = try leader()
        let invite = leader.act { $0.openJoining(now: Date(), lifetime: 1) }

        // The phone won't use it.
        let late = enrol(SquadEnroller(invite: invite, name: "Late", device: UUID(), queue: queue), at: leader.endpoint,
                         now: Date().addingTimeInterval(60))
        XCTAssertEqual(late, .failure(SquadLinkFailure("This invite has expired. Ask for a new one.")))

        // And if a phone's clock says otherwise, the leader's device won't take it.
        Thread.sleep(forTimeInterval: 2.2)
        let wrongClock = enrol(SquadEnroller(invite: invite, name: "Late", device: UUID(), queue: queue), at: leader.endpoint,
                               now: .distantPast)
        guard case .failure = wrongClock else { return XCTFail("joined with an expired invite") }
        XCTAssertTrue(leader.act { $0.squad.members.isEmpty })
        XCTAssertTrue(leader.act { $0.credentials.isEmpty })
    }

    /// A second device advertising the same squad. Without the invite's secret its link doesn't
    /// come up; with it (someone photographed the QR code), its answer isn't signed by the key
    /// the invite names.
    func testASecondDeviceAdvertisingTheSameSquadIsRefused() throws {
        let real = try leader()
        let invite = real.act { $0.openJoining(now: Date()) }

        let rogue = try Leader(core: SquadCore(squad: Squad(id: invite.squad, name: "Red"), mission: NoMission()), queue: queue)
        startLeader(rogue)
        addTeardownBlock { [queue] in queue.sync { rogue.host.stop() } }
        let roguesOwn = rogue.act { $0.openJoining(now: Date()) }

        let blind = enrol(SquadEnroller(invite: invite, name: "Ana", device: UUID(), queue: queue), at: rogue.endpoint)
        XCTAssertEqual(blind, .failure(SquadLinkFailure("This invite is no longer open. Ask for a new one.")))

        // The same invite the phone scanned, but the rogue holds its secret.
        let photographed = SquadInvite(squad: invite.squad, name: invite.name, enrol: roguesOwn.enrol, leader: invite.leader,
                                       expires: invite.expires)
        let answered = enrol(SquadEnroller(invite: photographed, name: "Ana", device: UUID(), queue: queue), at: rogue.endpoint)
        XCTAssertEqual(answered, .failure(SquadLinkFailure("Another device answered for Red. Not joined.")))
    }

    func testTheTypedCodeJoinsAndAWrongCodeDoesnt() throws {
        let leader = try leader()
        _ = leader.act { $0.openJoining(now: Date(), typedCode: true) }
        let code = try XCTUnwrap(leader.act { $0.joinCode })

        let wrong = enrol(SquadEnroller(squadName: "Red", code: code == "ABC234" ? "XYZ789" : "ABC234", name: "Eve", device: UUID(), queue: queue),
                          at: leader.endpoint)
        XCTAssertEqual(wrong, .failure(SquadLinkFailure("Couldn't join. Check the code, and that joining is open.")))

        let right = enrol(SquadEnroller(squadName: "Red", code: code.lowercased(), name: "Ana", device: UUID(), queue: queue), at: leader.endpoint)
        XCTAssertEqual(try right.get().squadName, "Red")

        // Closed: the same code no longer connects.
        leader.act { $0.closeJoining() }
        Thread.sleep(forTimeInterval: 0.3)
        let closed = enrol(SquadEnroller(squadName: "Red", code: code, name: "Ben", device: UUID(), queue: queue), at: leader.endpoint)
        guard case .failure = closed else { return XCTFail("joined after joining closed") }
        XCTAssertEqual(leader.act { $0.squad.members.map(\.name) }, ["Ana"])
    }

    /// Two apps' squads don't share keys: the right invite for the wrong app doesn't connect.
    func testAnotherAppsServiceCantConnect() throws {
        let other = try leader(service: SquadService(type: "_other._tcp", app: "Other", scheme: "other"))
        let invite = other.act { $0.openJoining(now: Date()) }
        let result = enrol(SquadEnroller(invite: invite, name: "Ana", device: UUID(), queue: queue), at: other.endpoint)
        guard case .failure = result else { return XCTFail("connected to another app's squad") }
        XCTAssertTrue(other.act { $0.squad.members.isEmpty })
    }

    // MARK: Credentials

    func testARemovedMemberIsCutOffAndCantReconnect() throws {
        let leader = try leader()
        let ana = try join(leader, name: "Ana")
        let ben = try join(leader, name: "Ben")

        let phone = client(ana, name: "Ana", at: leader)
        let linked = expectation(description: "linked")
        phone.onMessage = { m in if case .welcome = m.body { linked.fulfill() } }
        phone.start()
        wait(for: [linked], timeout: 10)

        leader.command { $0.removeMember(try! XCTUnwrap(ana.member), now: Date()) }
        XCTAssertEqual(waitForStop(phone), "Removed from the squad.")
        XCTAssertEqual(leader.act { $0.peers.count }, 0)

        // Its credential no longer opens a link: TLS has no such key.
        let again = client(ana, name: "Ana", at: leader)
        again.start()
        XCTAssertEqual(waitForStop(again), SquadLinkClient.notAccepted)

        // Ben is unaffected.
        let bens = client(ben, name: "Ben", at: leader)
        let benLinked = expectation(description: "Ben linked")
        bens.onMessage = { m in if case .welcome = m.body { benLinked.fulfill() } }
        bens.start()
        wait(for: [benLinked], timeout: 10)
        XCTAssertEqual(leader.act { $0.squad.members.map(\.name) }, ["Ben"])
    }

    /// TLS doesn't tell the leader which key a device used, so the device says, with a proof. A
    /// member naming someone else's credential is dropped.
    func testAMemberCantPassAsAnotherMember() throws {
        let leader = try leader()
        let ana = try join(leader, name: "Ana")
        let ben = try join(leader, name: "Ben")

        let phone = SquadConnection(to: leader.endpoint, key: ana.linkKey, queue: queue)
        phone.claim = LinkKey(identity: ben.linkKey.identity, key: ana.linkKey.key)
        let dropped = expectation(description: "dropped")
        dropped.assertForOverFulfill = false
        phone.onState = { s in
            if s == .ready { phone.send(.hello(Hello(name: "Ben", device: UUID()))) }
            if s == .closed { dropped.fulfill() }
            if case .failed = s { dropped.fulfill() }
        }
        phone.onMessage = { m in XCTFail("got \(m.body)") }
        phone.start()
        wait(for: [dropped], timeout: 10)
        XCTAssertEqual(leader.act { $0.peers.count }, 0)
    }

    /// The leader's device sleeping: its side of every link drops and its listener restarts. The
    /// phone's client finds it again and comes back as the same member.
    func testClientRejoinsAfterTheHostDrops() throws {
        let leader = try leader()
        let credential = try join(leader, name: "Ana")
        let port = leader.host.port

        let phone = client(credential, name: "Ana", at: leader)
        var welcomes: [MemberID] = []
        let first = expectation(description: "first welcome")
        let second = expectation(description: "welcome after the drop")
        var statuses: [SquadLinkClient.Status] = []
        phone.onStatus = { statuses.append($0) }
        phone.onMessage = { m in
            guard case let .welcome(w) = m.body else { return }
            welcomes.append(w.member)
            if welcomes.count == 1 { first.fulfill() } else if welcomes.count == 2 { second.fulfill() }
        }
        phone.start()
        wait(for: [first], timeout: 10)

        queue.sync {
            for c in leader.host.connections.values { c.cancel() }
            leader.host.restart()
        }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(welcomes, [credential.member, credential.member].compactMap { $0 }, "the same member")
        XCTAssertTrue(statuses.contains { if case .reconnecting = $0 { return true }; return false }, "\(statuses)")
        XCTAssertEqual(leader.host.port, port, "the restarted listener keeps its port")
    }

    /// Changing the keys starts a new listener. Links that are up must stay up through it.
    func testALinkStaysUpWhileOthersJoin() throws {
        let leader = try leader()
        let ana = try join(leader, name: "Ana")
        let phone = client(ana, name: "Ana", at: leader)
        let linked = expectation(description: "linked")
        let sawBen = expectation(description: "status with Ben")
        sawBen.assertForOverFulfill = false
        var statuses: [SquadLinkClient.Status] = []
        phone.onStatus = { statuses.append($0) }
        phone.onMessage = { m in
            if case .welcome = m.body { linked.fulfill() }
            if case let .status(s) = m.body, s.squad.members.contains(where: { $0.name == "Ben" }) { sawBen.fulfill() }
        }
        phone.start()
        wait(for: [linked], timeout: 10)

        _ = try join(leader, name: "Ben")
        wait(for: [sawBen], timeout: 10)
        XCTAssertFalse(statuses.contains { if case .reconnecting = $0 { return true }; return false }, "\(statuses)")
    }

    /// A host that accepts TCP and never answers: joining must give up, not hang.
    func testAHandshakeThatNeverAnswersEndsTheJoin() throws {
        let silent = try NWListener(using: .tcp)
        silent.newConnectionHandler = { c in c.start(queue: self.queue) }   // accept, say nothing
        let ready = expectation(description: "listening")
        silent.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        silent.start(queue: queue)
        wait(for: [ready], timeout: 5)
        defer { silent.cancel() }
        let enroller = SquadEnroller(squadName: "Red", code: "ABC234", name: "Eve", device: UUID(), queue: queue)
        enroller.timeout = 2
        let result = enrol(enroller, at: .hostPort(host: "127.0.0.1", port: silent.port!))
        guard case let .failure(why) = result else { return XCTFail() }
        XCTAssertTrue(why.reason.hasPrefix("Couldn't reach Red"), why.reason)
    }

    // MARK: Keychain

    func testCredentialsAndLeaderKeysRoundTripThroughTheKeychain() throws {
        let store = SquadKeychain(service: "squadkit.tests." + UUID().uuidString)
        var core = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let invite = core.openJoining(now: Date())
        let request = EnrolmentRequest(name: "Ana", device: UUID())
        core.linkOpened(PeerID("p"), identity: invite.linkKey.identity)
        guard case let .enrolled(answer)? = core.handle(SquadMessage(seq: 1, body: .hello(request.hello)), from: PeerID("p"), now: Date()).first?.body
        else { return XCTFail() }
        let credential = try request.accept(answer, invite: invite)

        do {
            try store.save(credential)
        } catch let failure as SquadKeychain.Failure {
            throw XCTSkip("no Keychain here (status \(failure.status))")
        }
        defer {
            try? store.removeCredential(for: credential.squad)
            try? store.removeLeaderKeys(for: core.squadID)
        }
        XCTAssertEqual(try store.credential(for: credential.squad), credential)
        XCTAssertNil(try store.credential(for: SquadID()))

        try store.save(core.keys, for: core.squadID)
        let keys = try XCTUnwrap(try store.leaderKeys(for: core.squadID))
        XCTAssertEqual(keys.root, core.keys.root)
        XCTAssertEqual(keys.publicKey, core.keys.publicKey)

        try store.removeCredential(for: credential.squad)
        XCTAssertNil(try store.credential(for: credential.squad))
    }
}
