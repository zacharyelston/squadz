import Foundation
import Network
import XCTest
import CoreGeo
import SquadKit
@testable import SquadLink

/// A squad through a real relay: the Rust relay from `relay/`, started here with TLS and a
/// certificate of its own making, so every link in these tests is pinned the way a phone's is.
/// Build it first (`cd relay && cargo build`); without the binary these tests are skipped.
final class RelayLinkTests: XCTestCase {
    static var process: Process?
    static var address: RelayAddress?
    static var folder: URL?
    let queue = DispatchQueue(label: "relay-link-test")

    override class func setUp() {
        super.setUp()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["SQUADZ_RELAY_BIN"].map(URL.init(fileURLWithPath:))
            ?? root.appendingPathComponent("relay/target/debug/squadz-relay")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder

        // A key, then a certificate for it. The extension makes it a version 3 certificate, which the relay needs.
        let key = folder.appendingPathComponent("key.pem").path, cert = folder.appendingPathComponent("cert.pem").path
        for arguments in [["ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", key],
                          ["req", "-x509", "-new", "-key", key, "-days", "2", "-subj", "/CN=relay.test",
                           "-addext", "subjectAltName=DNS:relay.test", "-out", cert]] {
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            openssl.arguments = arguments
            openssl.standardError = FileHandle.nullDevice
            openssl.standardOutput = FileHandle.nullDevice
            guard (try? openssl.run()) != nil else { return }
            openssl.waitUntilExit()
        }

        let relay = Process()
        relay.executableURL = binary
        relay.environment = ["RELAY_LISTEN": "127.0.0.1:0", "RELAY_DB": ":memory:",
                             "RELAY_TLS_CERT": cert, "RELAY_TLS_KEY": key]
        let out = Pipe()
        relay.standardOutput = out
        guard (try? relay.run()) != nil else { return }
        process = relay

        // "listening on 127.0.0.1:PORT with TLS", then "relay_pin PIN".
        var text = ""
        while !text.contains("relay_pin "), text.split(separator: "\n").count < 2 || !text.hasSuffix("\n") {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            text += String(decoding: chunk, as: UTF8.self)
        }
        let lines = text.split(separator: "\n").map(String.init)
        guard let port = lines.first?.split(separator: " ").first(where: { $0.hasPrefix("127.0.0.1:") })?.dropFirst("127.0.0.1:".count),
              let pin = lines.first(where: { $0.hasPrefix("relay_pin ") })?.dropFirst("relay_pin ".count) else { return }
        address = RelayAddress(text: "wss://127.0.0.1:\(port)", pin: String(pin))
    }

    override class func tearDown() {
        process?.terminate()
        process = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    private func relay() throws -> RelayAddress {
        try XCTUnwrap(Self.address, "the relay did not start")
    }

    override func setUpWithError() throws {
        if Self.address == nil { throw XCTSkip("No relay to test against. Build it first: cd relay && cargo build") }
    }

    /// A leader whose squad has a room on the relay, and optionally a local listener too.
    final class Leader {
        var core: SquadCore<NoMission>
        var relay: RelayLinkHost
        var local: SquadLinkHost?
        var token: Data?
        let queue: DispatchQueue
        let name: String

        init(address: RelayAddress, local: Bool, queue: DispatchQueue) throws {
            name = "Relay Test \(UUID().uuidString.prefix(8))"
            core = SquadCore(squad: Squad(name: name), mission: NoMission(), sharesPositions: true)
            self.queue = queue
            relay = RelayLinkHost(address: address, squad: core.squadID, token: nil, keys: [], queue: queue)
            if local {
                let host = try SquadLinkHost(name: name, keys: [], advertise: false, queue: queue)
                host.onOpened = { [unowned self] peer, identity in self.core.linkOpened(peer, identity: identity) }
                host.onMessage = { [unowned self] m, peer in self.send(self.core.handle(m, from: peer, now: Date())) }
                host.onPeerClosed = { [unowned self] peer in self.core.peerClosed(peer) }
                self.local = host
            }
            wire()
        }

        func wire() {
            relay.onOpened = { [unowned self] peer, identity in self.core.linkOpened(peer, identity: identity) }
            relay.onMessage = { [unowned self] m, peer in self.send(self.core.handle(m, from: peer, now: Date())) }
            relay.onPeerClosed = { [unowned self] peer in self.core.peerClosed(peer) }
            relay.onToken = { [unowned self] token in self.token = token }
        }

        func send(_ out: [Outgoing]) {
            relay.send(out)
            local?.send(out)
            relay.setKeys(core.linkKeys(now: Date()), invites: core.relayInvites(now: Date()))
            local?.setKeys(core.linkKeys(now: Date()))
        }

        /// One of the leader's own actions. Returns once the relay has had time to hear of it.
        func act<T>(_ action: (inout SquadCore<NoMission>) -> T) -> T {
            let result = queue.sync { () -> T in
                let result = action(&core)
                send([])
                return result
            }
            settle()
            return result
        }

        func command(_ action: (inout SquadCore<NoMission>) -> [Outgoing]) {
            queue.sync { send(action(&core)) }
            settle()
        }

        func settle() {
            Thread.sleep(forTimeInterval: 0.2)
            if let local { for _ in 0..<500 where !queue.sync(execute: { local.isListening }) { Thread.sleep(forTimeInterval: 0.01) } }
        }

        var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: local!.port!)!) }
    }

    private func open(_ host: RelayLinkHost) {
        let opened = expectation(description: "room open")
        opened.assertForOverFulfill = false
        queue.sync {
            host.onStatus = { if $0 == .open { opened.fulfill() } }
            host.start()
        }
        wait(for: [opened], timeout: 5)
    }

    private func leader(local: Bool = false) throws -> Leader {
        let l = try Leader(address: try relay(), local: local, queue: queue)
        if let host = l.local {
            let ready = expectation(description: "listening")
            ready.assertForOverFulfill = false
            host.onReady = { _ in ready.fulfill() }
            host.start()
            wait(for: [ready], timeout: 5)
        }
        open(l.relay)
        addTeardownBlock { [queue] in queue.sync { l.relay.stop(endSquad: true); l.local?.stop() } }
        return l
    }

    /// The invite as a phone gets it: through its link form, relay and pin included.
    private func invite(_ leader: Leader) throws -> SquadInvite {
        var shown = leader.act { $0.openJoining(now: Date(), by: "Leader's iPad") }
        shown.relay = leader.relay.address
        return try SquadInvite(url: shown.url(scheme: "squadz"), scheme: "squadz")
    }

    private func enrol(_ invite: SquadInvite, name: String, at endpoint: NWEndpoint? = nil) -> Result<MemberCredential, SquadLinkFailure> {
        let enroller = SquadEnroller(invite: invite, name: name, device: UUID(), queue: queue)
        enroller.fixedEndpoint = endpoint
        enroller.relayAfter = 0.1
        let done = expectation(description: "enrolment answered")
        var result: Result<MemberCredential, SquadLinkFailure> = .failure(SquadLinkFailure("no answer"))
        enroller.onDone = { result = $0; done.fulfill() }
        queue.sync { enroller.start() }
        wait(for: [done], timeout: 15)
        return result
    }

    private func client(_ credential: MemberCredential, name: String) -> SquadLinkClient {
        let c = SquadLinkClient(credential: credential, name: name, device: UUID(), queue: queue)
        c.relayAfter = 0.1
        c.baseDelay = 0.2
        addTeardownBlock { [queue] in queue.sync { c.stop() } }
        return c
    }

    /// Starts the client and waits for the leader's welcome.
    @discardableResult
    private func connect(_ c: SquadLinkClient) -> Welcome? {
        let welcomed = expectation(description: "welcomed")
        welcomed.assertForOverFulfill = false
        var welcome: Welcome?
        queue.sync {
            c.onMessage = { m in if case let .welcome(w) = m.body { welcome = w; welcomed.fulfill() } }
            c.start()
        }
        wait(for: [welcomed], timeout: 10)
        return welcome
    }

    private func waitForStop(_ client: SquadLinkClient, timeout: TimeInterval = 20) -> String {
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

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ check: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if queue.sync(execute: check) { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("never happened: \(what)")
    }

    // MARK: Tests

    func testAPhoneJoinsAndLinksThroughTheRelay() throws {
        let leader = try leader()
        let scanned = try invite(leader)
        XCTAssertEqual(scanned.relay, leader.relay.address)

        let credential = try enrol(scanned, name: "Ana").get()
        XCTAssertEqual(credential.relay?.address, leader.relay.address)
        XCTAssertEqual(credential.relay?.token.count, 32)
        XCTAssertEqual(queue.sync { leader.core.squad.members.map(\.name) }, ["Ana"])

        let phone = client(credential, name: "Ana")
        let welcome = connect(phone)
        XCTAssertEqual(welcome?.member, credential.member)
        XCTAssertTrue(queue.sync { phone.isRelayed })

        // Her position reaches the leader's device, and the leader's orders reach her.
        let here = MemberPosition(at: GeoPoint(latitude: 51.5, longitude: -0.12), accuracy: 5, time: Date())
        queue.sync { phone.send(.position(here)) }
        eventually("the leader has Ana's position") { leader.core.positions[credential.member!]?.at == here.at }

        let ordered = expectation(description: "order arrived")
        queue.sync { phone.onMessage = { m in if case .order = m.body { ordered.fulfill() } } }
        leader.command { $0.sendOrder(.note, text: "On me", now: Date()) }
        wait(for: [ordered], timeout: 5)
    }

    func testTwoMembersSeeEachOtherThroughTheRelay() throws {
        let leader = try leader()
        let ana = try enrol(try invite(leader), name: "Ana").get()
        let ben = try enrol(try invite(leader), name: "Ben").get()
        let anaPhone = client(ana, name: "Ana"), benPhone = client(ben, name: "Ben")
        connect(anaPhone)
        connect(benPhone)

        let seen = expectation(description: "Ben sees Ana")
        seen.assertForOverFulfill = false
        queue.sync {
            benPhone.onMessage = { m in
                if case let .positions(report) = m.body, report.positions.contains(where: { $0.member == ana.member }) { seen.fulfill() }
            }
            anaPhone.send(.position(MemberPosition(at: GeoPoint(latitude: 1, longitude: 2), accuracy: 5, time: Date())))
        }
        wait(for: [seen], timeout: 5)
    }

    func testJoiningOnTheLocalNetworkAlsoGetsATicketForLater() throws {
        let leader = try leader(local: true)
        let credential = try enrol(try invite(leader), name: "Ana", at: leader.endpoint).get()
        XCTAssertNotNil(credential.relay, "joined locally, but no relay ticket")

        // Later, away from the leader's network: nothing local to find, so the relay it is.
        let phone = client(credential, name: "Ana")
        connect(phone)
        XCTAssertTrue(queue.sync { phone.isRelayed })
    }

    func testOnTheSameNetworkTheLocalLinkIsUsed() throws {
        let leader = try leader(local: true)
        let credential = try enrol(try invite(leader), name: "Ana", at: leader.endpoint).get()
        let phone = client(credential, name: "Ana")
        phone.fixedEndpoint = leader.endpoint
        connect(phone)
        XCTAssertFalse(queue.sync { phone.isRelayed })
    }

    func testAClosedInviteIsClosedAtTheRelayToo() throws {
        let leader = try leader()
        let scanned = try invite(leader)
        leader.act { $0.closeJoining() }
        guard case let .failure(why) = enrol(scanned, name: "Late") else { return XCTFail("joined on a closed invite") }
        XCTAssertEqual(why.reason, "This invite is no longer open. Ask for a new one.")
        XCTAssertEqual(queue.sync { leader.core.squad.members.count }, 0)
    }

    func testARelayShowingAnotherCertificateIsRefused() throws {
        let leader = try leader()
        var scanned = try invite(leader)

        scanned.relay?.pin = Data(repeating: 7, count: 32)
        guard case let .failure(wrongPin) = enrol(scanned, name: "Ana") else { return XCTFail("joined through a relay with the wrong certificate") }
        XCTAssertEqual(wrongPin.reason, RelayLink.wrongCertificate)

        // With no pin the certificate has to check out the usual way, and this one is self-made.
        scanned.relay?.pin = nil
        guard case let .failure(unpinned) = enrol(scanned, name: "Ana") else { return XCTFail("trusted a self-made certificate without a pin") }
        XCTAssertEqual(unpinned.reason, RelayLink.wrongCertificate)
        XCTAssertEqual(queue.sync { leader.core.squad.members.count }, 0)
    }

    func testARelayTicketAloneDoesntMakeAMember() throws {
        let leader = try leader()
        let ana = try enrol(try invite(leader), name: "Ana").get()
        let ben = try enrol(try invite(leader), name: "Ben").get()

        // Ben's ticket and Ben's key, claiming to be Ana.
        let failed = expectation(description: "refused")
        failed.assertForOverFulfill = false
        var reason = ""
        let phone = SquadConnection(through: ben.relay!, squad: ben.squad, key: ben.linkKey, queue: queue)
        phone.claim = LinkKey(identity: ana.linkKey.identity, key: ben.linkKey.key)
        phone.onState = { s in if case let .failed(why) = s { reason = why; failed.fulfill() } }
        queue.sync { phone.start() }
        wait(for: [failed], timeout: 5)
        XCTAssertTrue(reason.hasPrefix(SquadConnection.refusedKey), reason)
        XCTAssertTrue(queue.sync { leader.core.peers.isEmpty })

        // A ticket with a key the leader never issued gets no further.
        var stranger = ben
        stranger.id = .random(16)
        stranger.secret = .random(32)
        let c = client(stranger, name: "Stranger")
        queue.sync { c.start() }
        XCTAssertEqual(waitForStop(c), SquadLinkClient.notAccepted)
    }

    func testARemovedMemberIsCutOffThroughTheRelay() throws {
        let leader = try leader()
        let ana = try enrol(try invite(leader), name: "Ana").get()
        let phone = client(ana, name: "Ana")
        connect(phone)

        leader.command { $0.removeMember(ana.member!, now: Date()) }
        XCTAssertFalse(waitForStop(phone).isEmpty)

        // Her ticket still opens a link at the relay; the leader's device turns her key down.
        let again = client(ana, name: "Ana")
        queue.sync { again.start() }
        XCTAssertEqual(waitForStop(again), SquadLinkClient.notAccepted)
    }

    func testALeaderThatRestartsLeadsItsRoomAgain() throws {
        let leader = try leader()
        let ana = try enrol(try invite(leader), name: "Ana").get()
        let phone = client(ana, name: "Ana")
        connect(phone)
        let token = try XCTUnwrap(queue.sync { leader.token })

        // The leader's app goes away and comes back with the token it kept.
        let welcomedAgain = expectation(description: "welcomed again")
        welcomedAgain.assertForOverFulfill = false
        queue.sync {
            phone.onMessage = { m in if case .welcome = m.body { welcomedAgain.fulfill() } }
            leader.relay.stop()
            for peer in leader.core.peers.keys { leader.core.peerClosed(peer) }
            leader.relay = RelayLinkHost(address: leader.relay.address, squad: leader.core.squadID, token: token,
                                         keys: leader.core.linkKeys(now: Date()), queue: queue)
            leader.wire()
        }
        open(leader.relay)
        wait(for: [welcomedAgain], timeout: 15)

        // A wrong token leads nothing.
        let stopped = expectation(description: "refused")
        let impostor = RelayLinkHost(address: leader.relay.address, squad: leader.core.squadID, token: Data(repeating: 1, count: 32), keys: [], queue: queue)
        queue.sync {
            impostor.onStatus = { if case .stopped = $0 { stopped.fulfill() } }
            impostor.start()
        }
        wait(for: [stopped], timeout: 5)

        // The leader ends the squad: the relay forgets it, and the real token leads nothing either.
        queue.sync { leader.relay.stop(endSquad: true) }
        Thread.sleep(forTimeInterval: 0.7)
        let gone = expectation(description: "the room is gone")
        let after = RelayLinkHost(address: leader.relay.address, squad: leader.core.squadID, token: token, keys: [], queue: queue)
        queue.sync {
            after.onStatus = { if case .stopped = $0 { gone.fulfill() } }
            after.start()
        }
        wait(for: [gone], timeout: 5)
    }
}
