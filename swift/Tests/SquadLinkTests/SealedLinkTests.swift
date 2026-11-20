import Foundation
import XCTest
import CoreGeo
import SquadKit
@testable import SquadLink

/// A link something else carries (docs/WIRE.md §9), with the carrier played here: it sees every
/// byte and may change, drop or add any. No relay is needed for these.
final class SealedLinkTests: XCTestCase {
    let queue = DispatchQueue(label: "sealed-link-test")

    /// One end of a carried link. `carry` is the carrier: what it does with each message on its
    /// way out of this end.
    final class CarriedPipe: LinkPipe {
        var onEvent: ((PipeEvent) -> Void)?
        weak var other: CarriedPipe?
        var carry: (Data) -> Data? = { $0 }
        private(set) var refused = false
        private let queue: DispatchQueue
        private let carrier: Data

        init(carrier: Data, queue: DispatchQueue) {
            self.carrier = carrier
            self.queue = queue
        }

        /// A relay tells a device its link is open before it passes anything on.
        private var up = false
        private var waiting: [Data] = []

        func start() {
            queue.async {
                self.up = true
                self.onEvent?(.up(binding: self.carrier))
                for bytes in self.waiting { self.onEvent?(.bytes(bytes)) }
                self.waiting = []
            }
        }

        private func receive(_ bytes: Data) {
            if up { onEvent?(.bytes(bytes)) } else { waiting.append(bytes) }
        }

        func send(_ bytes: Data, thenClose: Bool) {
            queue.async {
                if let carried = self.carry(bytes) { self.other?.receive(carried) }
                if thenClose { self.cancel() }
            }
        }

        func cancel() {
            queue.async {
                self.onEvent?(.closed)
                self.other?.onEvent?(.closed)
            }
        }

        func refuse() {
            refused = true
            queue.async {
                self.other?.onEvent?(.failed("\(SquadConnection.refusedKey) (through the carrier)."))
                self.onEvent?(.closed)
            }
        }

        /// The carrier speaks for itself.
        func inject(_ bytes: Data) { queue.async { self.other?.receive(bytes) } }
    }

    /// A leader's device and the links into it.
    final class Leader {
        var core = SquadCore(squad: Squad(name: "Sealed Test Squad"), mission: NoMission(), sharesPositions: true)
        var links: [PeerID: SquadConnection] = [:]
        var pipes: [CarriedPipe] = []
        let queue: DispatchQueue

        init(queue: DispatchQueue) { self.queue = queue }

        /// The leader's end of a new link, and the pipe a device's end goes on.
        func accept() -> (leader: CarriedPipe, device: CarriedPipe) {
            let carrier = Data.random(32)
            let mine = CarriedPipe(carrier: carrier, queue: queue), theirs = CarriedPipe(carrier: carrier, queue: queue)
            mine.other = theirs
            theirs.other = mine
            pipes += [mine, theirs]
            let peer = PeerID(UUID().uuidString)
            let c = SquadConnection(accepting: mine, peer: peer, keys: core.linkKeys(now: Date()), relayed: true, queue: queue)
            c.onState = { [unowned self, weak c] s in
                switch s {
                case .ready: if let identity = c?.identity { self.core.linkOpened(peer, identity: identity) }
                case .failed, .closed: self.core.peerClosed(peer)
                case .connecting: break
                }
            }
            c.onMessage = { [unowned self] m in self.send(self.core.handle(m, from: peer, now: Date())) }
            links[peer] = c
            c.start()
            return (mine, theirs)
        }

        func send(_ out: [Outgoing]) {
            for o in out { links[o.to]?.send(o.body, thenClose: o.thenClose) }
        }
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ check: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if queue.sync(execute: check) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("never happened: \(what)")
    }

    /// Joins on `pipe` and returns the credential. `nil` if the leader's device never answered.
    private func join(_ invite: SquadInvite, name: String, on pipe: CarriedPipe) -> MemberCredential? {
        let request = EnrolmentRequest(name: name, device: UUID())
        let c = SquadConnection(over: pipe, key: invite.linkKey, relayed: true, queue: queue)
        var credential: MemberCredential?
        var ended = false
        c.onState = { s in
            switch s {
            case .ready: c.send(.hello(request.hello))
            case .failed, .closed: ended = true
            case .connecting: break
            }
        }
        c.onMessage = { m in if case let .enrolled(e) = m.body { credential = try? request.accept(e, invite: invite) } }
        queue.sync { c.start() }
        let end = Date().addingTimeInterval(3)
        while Date() < end, !queue.sync(execute: { credential != nil || ended }) { Thread.sleep(forTimeInterval: 0.01) }
        queue.sync { c.onState = nil; c.onMessage = nil }
        return queue.sync { credential }
    }

    func testEverythingCrossesSealedAndNothingReadable() throws {
        let leader = Leader(queue: queue)
        var seen = Data()
        func watched() -> CarriedPipe {
            let (mine, theirs) = queue.sync { leader.accept() }
            mine.carry = { seen.append($0); return $0 }
            theirs.carry = { seen.append($0); return $0 }
            return theirs
        }

        let invite = queue.sync { leader.core.openJoining(now: Date(), by: "Leader's iPad") }
        let credential = try XCTUnwrap(join(invite, name: "Anastasia", on: watched()))
        XCTAssertEqual(queue.sync { leader.core.squad.members.map(\.name) }, ["Anastasia"])

        let phone = SquadConnection(over: watched(), key: credential.linkKey, relayed: true, queue: queue)
        var heard: [String] = []
        phone.onState = { if $0 == .ready { phone.send(.hello(Hello(name: "Anastasia", device: UUID()))) } }
        phone.onMessage = { heard.append($0.type) }
        queue.sync { phone.start() }
        eventually("welcomed") { heard.contains("welcome") }

        let here = GeoPoint(latitude: 51.50741, longitude: -0.12783)
        queue.sync {
            phone.send(.position(MemberPosition(at: here, accuracy: 5, time: Date())))
            phone.send(.note(FieldNote(author: "Anastasia", time: Date(), text: "Hedge by the old gate")))
            leader.send(leader.core.sendOrder(.note, text: "On me at the shed", now: Date()))
        }
        eventually("the position arrived") { leader.core.positions[credential.member!]?.at == here }
        eventually("the order arrived") { heard.contains("order") }

        let log = queue.sync { seen }
        XCTAssertGreaterThan(log.count, 1000)
        XCTAssertNotNil(log.range(of: Data(#""type":"seal""#.utf8)), "the nonces cross in the clear, so this log would show anything else that did")
        for word in ["Anastasia", "Sealed Test Squad", "Hedge by the old gate", "On me at the shed", "51.50741", "0.12783",
                     "hello", "welcome", "position", "enrolled", "status", credential.member!.raw.uuidString] {
            XCTAssertNil(log.range(of: Data(word.utf8)), "the carrier saw \(word)")
        }
    }

    /// What a relay could do before frames were sealed: let the device prove its key, then put its
    /// own request to join in place of the device's.
    func testACarrierCantJoinInPlaceOfTheDeviceJoining() throws {
        let leader = Leader(queue: queue)
        let invite = queue.sync { leader.core.openJoining(now: Date()) }
        let (mine, theirs) = queue.sync { leader.accept() }
        let own = EnrolmentRequest(name: "Carrier", device: UUID())
        var count = 0
        theirs.carry = { bytes in
            count += 1
            // The device's nonce goes through; its request to join is swapped for the carrier's.
            return count == 1 ? bytes : try? SquadWire.encode(SquadMessage(seq: 2, body: .hello(own.hello)))
        }
        XCTAssertNil(join(invite, name: "Ana", on: theirs))
        XCTAssertTrue(queue.sync { mine.refused })
        XCTAssertTrue(queue.sync { leader.core.squad.members.isEmpty && leader.core.peers.isEmpty })
    }

    func testAChangedFrameEndsTheLinkAndCountsForNothing() throws {
        let leader = Leader(queue: queue)
        let invite = queue.sync { leader.core.openJoining(now: Date()) }
        let credential = try XCTUnwrap(join(invite, name: "Ana", on: queue.sync { leader.accept() }.device))

        let (_, theirs) = queue.sync { leader.accept() }
        var count = 0
        theirs.carry = { bytes in
            count += 1
            guard count == 3 else { return bytes }   // nonce, hello, then her first position
            var changed = bytes
            changed[changed.count - 1] ^= 1
            return changed
        }
        let phone = SquadConnection(over: theirs, key: credential.linkKey, relayed: true, queue: queue)
        var welcomed = false, ended = false
        phone.onState = { s in
            switch s {
            case .ready: phone.send(.hello(Hello(name: "Ana", device: UUID())))
            case .failed, .closed: ended = true
            case .connecting: break
            }
        }
        phone.onMessage = { if case .welcome = $0.body { welcomed = true } }
        queue.sync { phone.start() }
        eventually("welcomed") { welcomed }
        queue.sync { phone.send(.position(MemberPosition(at: GeoPoint(latitude: 1, longitude: 2), accuracy: 5, time: Date()))) }
        eventually("the link ended") { ended }
        XCTAssertNil(queue.sync { leader.core.positions[credential.member!] })
        XCTAssertTrue(queue.sync { leader.core.peers.isEmpty })
    }

    func testARecordedLinkDoesntPlayBack() throws {
        let leader = Leader(queue: queue)
        let invite = queue.sync { leader.core.openJoining(now: Date()) }
        let credential = try XCTUnwrap(join(invite, name: "Ana", on: queue.sync { leader.accept() }.device))

        // A good link, recorded from the device's side.
        var recorded: [Data] = []
        let (_, theirs) = queue.sync { leader.accept() }
        theirs.carry = { recorded.append($0); return $0 }
        let phone = SquadConnection(over: theirs, key: credential.linkKey, relayed: true, queue: queue)
        phone.onState = { if $0 == .ready { phone.send(.hello(Hello(name: "Ana", device: UUID()))) } }
        queue.sync { phone.start() }
        eventually("she is linked") { leader.core.peers.count == 1 }
        queue.sync { phone.cancel() }
        eventually("she is gone") { leader.core.peers.isEmpty }
        XCTAssertEqual(queue.sync { recorded.count }, 2)

        // The carrier opens a link of its own and plays her frames into it.
        let (mine, replay) = queue.sync { leader.accept() }
        for frame in queue.sync(execute: { recorded }) { replay.inject(frame) }
        eventually("the leader's device turned it down") { mine.refused }
        XCTAssertTrue(queue.sync { leader.core.peers.isEmpty })
    }

    func testAKeyTheLeaderNeverIssuedIsRefused() throws {
        let leader = Leader(queue: queue)
        let (mine, theirs) = queue.sync { leader.accept() }
        let stranger = SquadConnection(over: theirs, key: LinkKey(identity: "m:" + Data.random(16).hex, key: .random(32)), relayed: true, queue: queue)
        var reason = ""
        stranger.onState = { if case let .failed(why) = $0 { reason = why } }
        queue.sync { stranger.start() }
        eventually("refused") { !reason.isEmpty }
        XCTAssertTrue(reason.hasPrefix(SquadConnection.refusedKey), reason)
        XCTAssertTrue(queue.sync { mine.refused })
    }
}
