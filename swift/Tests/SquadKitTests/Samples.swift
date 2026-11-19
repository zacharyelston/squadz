import Foundation
import CoreGeo
@testable import SquadKit

func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

let origin = GeoPoint(latitude: 42.36, longitude: -71.06)

/// A small deterministic generator, so a failing fuzz run can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Samples {
    /// One sample of every message body, with fixed IDs and times. The switch makes a new case
    /// fail to compile until it's added here, so everything that scans these covers the whole
    /// protocol. testdata/wire/messages.json is these, as they cross the wire.
    static func all() -> [SquadMessage.Body] {
        let t = Date(timeIntervalSince1970: 1_800_000_000.25)   // the wire keeps milliseconds
        let ana = Member(id: MemberID(uuid(2)), name: "Ana", device: uuid(3), role: .member)
        let squad = Squad(id: SquadID(uuid(1)), name: "Red", members: [ana])
        let bytes = { (n: UInt8, count: Int) in Data(repeating: n, count: count) }
        let sealed = SealedCredential(id: bytes(1, 16), epoch: 0, issued: t, key: bytes(4, 65), sealed: bytes(5, 60))
        let all: [SquadMessage.Body] = [
            .link(LinkProof(id: "m:" + bytes(1, 16).hex, proof: bytes(2, 32))),
            .hello(Hello(name: "Ana", device: uuid(3), nonce: bytes(3, 16), key: bytes(6, 65))),
            .hello(Hello(name: "Watcher", device: uuid(4), role: .observer, nonce: bytes(3, 16))),
            .enrolled(Enrolled(squad: squad.id, name: "Red", member: ana.id, role: .member, credential: sealed,
                               leader: bytes(7, 65), signature: bytes(8, 64))),
            .leaderKey(LeaderKeyChange(squad: squad.id, key: bytes(9, 65), time: t, signature: bytes(8, 64))),
            .bye,
            .position(MemberPosition(at: origin, accuracy: 3, heading: 12, time: t)),
            .orderAck(OrderAck(order: uuid(5), response: .done)),
            .checkFire(CheckFire(id: uuid(6), by: "Ana")),
            .note(FieldNote(id: uuid(7), author: "Ana", time: t, field: "north-ridge", at: origin, accuracy: 3,
                            text: "Hedge", photo: Data([1, 2]))),
            .fileOffer(FileOffer(id: uuid(8), kind: .capture, group: uuid(9), name: "shot-1.jpg", size: 10, sha256: "ab", field: "north-ridge")),
            .fileChunk(FileChunk(file: uuid(8), index: 0, data: Data([1, 2, 3]))),
            .fileDone(uuid(8)),
            .welcome(Welcome(member: ana.id, squad: squad)),
            .observing(squad),
            .refused("Joining is closed."),
            .status(SquadStatus(revision: 4, squad: squad,
                                holds: [.checkFire(by: "Ana"),
                                        Hold(source: "test.rally", kind: "notAtRally", member: ana.id, text: "Ana isn't at the rally point.")],
                                missions: [MissionStatus(id: "test.rally", version: 1, payload: Data(#"{"rally":null}"#.utf8))])),
            .order(Order(id: uuid(10), kind: .moveTo, text: "Left flank, by the shed", at: origin, to: [ana.id], time: t)),
            .order(Order(id: uuid(11), kind: Order.Kind(rawValue: "test.rally.regroup"), text: "Regroup", time: t)),
            .receipt(Receipt(id: uuid(7), status: .stored, detail: "ok")),
            .positions(PositionsReport(squad: squad.id, positions: [MemberPosition(member: ana.id, at: origin, accuracy: 2, time: t)])),
            .mission(MissionMessage(id: "test.rally", version: 1, payload: Data(#"{"arrived":true}"#.utf8))),
        ]
        for body in all {
            switch body {   // exhaustive on purpose
            case .link, .enrolled, .leaderKey, .hello, .bye, .position, .orderAck, .checkFire, .note, .fileOffer, .fileChunk, .fileDone,
                 .welcome, .observing, .refused, .status, .order, .receipt, .positions, .mission: break
            }
        }
        return all
    }
}

/// A mission with nothing but a rally point the leader sets. Members report arriving.
struct RallyMission: Mission {
    static let id = "test.rally"
    static let version = 1
    static let orderKinds = [Order.Kind(rawValue: "test.rally.regroup")]

    struct Arrived: Codable { var arrived: Bool }
    struct Status: Codable, Equatable { var rally: GeoPoint?; var arrived: [MemberID] }

    var rally: GeoPoint?
    var arrived: Set<MemberID> = []
    var handled = 0
    /// Set to make this mission misbehave: it returns no holds whatever is going on, and asks the
    /// core to send whatever it likes.
    var hostile = false

    mutating func handle(_ payload: Data, from member: MemberID, peer: PeerID, core: CoreView, now: Date) -> MissionStep {
        handled += 1
        guard let m = try? JSONDecoder().decode(Arrived.self, from: payload) else { return .problem("Bad rally message.") }
        if m.arrived { arrived.insert(member) } else { arrived.remove(member) }
        return .changed()
    }

    func holds(core: CoreView, now: Date) -> Set<Hold> {
        guard !hostile, rally != nil else { return [] }
        return Set(core.squad.members.filter { !arrived.contains($0.id) }.map {
            Hold(source: Self.id, kind: "notAtRally", member: $0.id, text: "\($0.name) isn't at the rally point.")
        })
    }

    func observerWelcome(core: CoreView) -> [Data] { [Data("hello observer".utf8)] }

    func status(core: CoreView, now: Date) -> Data? {
        try? SquadWire.encoder.encode(Status(rally: rally, arrived: arrived.sorted { $0.raw.uuidString < $1.raw.uuidString }))
    }
}

/// A squad's leader and its phones on the loopback network.
final class Yard<M: Mission> {
    let net = LoopbackNetwork()
    let leader = PeerID("leader")
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var host: SquadCore<M>
    var got: [String: [SquadMessage.Body]] = [:]
    var devices: [String: UUID] = [:]

    var credentials: [String: MemberCredential] = [:]
    lazy var invite = host.openJoining(now: now)

    init(mission: M) {
        host = SquadCore(squad: Squad(name: "Red"), mission: mission)
        net.add(leader) { [unowned self] m, from in self.host.handle(m, from: from, now: self.now) }
    }

    func peer(_ name: String) -> PeerID { PeerID("phone-" + name) }

    /// Joins with the open invite the first time, then connects with the credential that gave.
    /// A second call is the same device coming back on a new link.
    @discardableResult
    func join(_ name: String, role: Hello.Role? = nil) -> MemberID? {
        let device = devices[name] ?? UUID()
        devices[name] = device
        if credentials[name] == nil {
            let door = PeerID("invite-" + name)
            let request = EnrolmentRequest(name: name, device: device, role: role)
            var answer: Enrolled?
            var refusal: SquadMessage.Body?
            net.add(door) { m, _ in
                if case let .enrolled(e) = m.body { answer = e }
                if case .refused = m.body { refusal = m.body }
                return []
            }
            host.linkOpened(door, identity: invite.linkKey.identity)
            net.send(from: door, [Outgoing(to: leader, .hello(request.hello))])
            net.run()
            host.peerClosed(door)
            guard let answer, let credential = try? request.accept(answer, invite: invite) else {
                if let refusal { got[name, default: []].append(refusal) }
                return nil
            }
            credentials[name] = credential
        }
        guard let credential = credentials[name] else { return nil }
        net.add(peer(name)) { [unowned self] m, _ in self.got[name, default: []].append(m.body); return [] }
        host.linkOpened(peer(name), identity: credential.linkKey.identity)
        send(name, .hello(Hello(name: name, device: device, role: role)))
        return credential.member
    }

    func send(_ name: String, _ body: SquadMessage.Body) {
        net.send(from: peer(name), [Outgoing(to: leader, body)])
        net.run()
    }

    func command(_ action: (inout SquadCore<M>, Date) -> [Outgoing]) {
        let out = action(&host, now)
        net.send(from: leader, out)
        net.run()
    }

    func has(_ name: String, _ match: (SquadMessage.Body) -> Bool) -> Bool { got[name, default: []].contains(where: match) }
    func lastStatus(_ name: String) -> SquadStatus? {
        got[name, default: []].reversed().lazy.compactMap { if case let .status(s) = $0 { return s } else { return nil } }.first
    }
}
