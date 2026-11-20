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
        let all: [SquadMessage.Body] = [
            .hello(Hello(name: "Ana", device: uuid(3), joinCode: "RED234")),
            .hello(Hello(name: "Watcher", device: uuid(4), joinCode: "RED234", role: .observer)),
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
            .refused("Wrong join code."),
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
            case .hello, .bye, .position, .orderAck, .checkFire, .note, .fileOffer, .fileChunk, .fileDone,
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

    init(mission: M, code: String = "RED234") {
        host = SquadCore(squad: Squad(name: "Red"), mission: mission, joinCode: code)
        net.add(leader) { [unowned self] m, from in self.host.handle(m, from: from, now: self.now) }
    }

    func peer(_ name: String) -> PeerID { PeerID("phone-" + name) }

    @discardableResult
    func join(_ name: String, code: String = "RED234", role: Hello.Role? = nil) -> MemberID? {
        let device = devices[name] ?? UUID()
        devices[name] = device
        net.add(peer(name)) { [unowned self] m, _ in self.got[name, default: []].append(m.body); return [] }
        send(name, .hello(Hello(name: name, device: device, joinCode: code, role: role)))
        return host.squad.members.first { $0.device == device }?.id
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
