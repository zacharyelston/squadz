import Foundation
import XCTest
import CoreGeo
@testable import SquadKit

/// The squad core on its own: join, roster, positions, orders, notes, check fire, observers.
final class SquadCoreTests: XCTestCase {

    func testASquadWithNoMission() throws {
        let y = Yard(mission: NoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        y.join("Watcher", role: .observer)
        XCTAssertEqual(y.host.squad.members.map(\.name), ["Ana"], "an observer isn't on the roster")
        XCTAssertEqual(y.host.squad.members.first?.role, .member)
        guard case .welcome? = y.got["Ana"]?.first else { return XCTFail("\(y.got)") }
        guard case .observing? = y.got["Watcher"]?.first else { return XCTFail("\(y.got)") }
        XCTAssertEqual(y.lastStatus("Ana")?.missions, [], "no mission, no mission section")

        // A position goes to observers, stamped with the member the link belongs to.
        y.send("Ana", .position(MemberPosition(member: MemberID(), at: origin, accuracy: 3, time: y.now)))
        XCTAssertEqual(y.host.positions[ana]?.member, ana)
        XCTAssertTrue(y.has("Watcher") { if case let .positions(r) = $0 { return r.positions.map(\.member) == [ana] }; return false })

        // An order reaches the member and the observer.
        y.command { $0.sendOrder(.moveTo, text: "To the oak", at: origin, now: $1) }
        XCTAssertTrue(y.has("Ana") { if case .order = $0 { return true }; return false })
        XCTAssertTrue(y.has("Watcher") { if case .order = $0 { return true }; return false })

        // Check fire from the phone holds the squad. Only the leader lifts it.
        y.send("Ana", .checkFire(CheckFire(by: "Ana")))
        XCTAssertEqual(y.host.holds(now: y.now), [.checkFire(by: "Ana")])
        XCTAssertEqual(y.lastStatus("Ana")?.holds, [.checkFire(by: "Ana")])
        y.command { $0.withdrawCheckFire(now: $1) }
        XCTAssertTrue(y.host.holds(now: y.now).isEmpty)
        XCTAssertEqual(y.lastStatus("Watcher")?.holds, [])
    }

    func testJoinCodesRejoinAndRemoval() throws {
        let y = Yard(mission: NoMission())
        XCTAssertNil(y.join("Eve", code: "WRONG1"))
        XCTAssertTrue(y.has("Eve") { $0 == .refused("Wrong join code.") })
        XCTAssertTrue(y.host.squad.members.isEmpty)

        let ana = try XCTUnwrap(y.join("Ana"))
        let ben = try XCTUnwrap(y.join("Ben"))
        // Ana drops and comes back on a new link, as the same member.
        y.send("Ana", .bye)
        XCTAssertEqual(y.join("Ana"), ana)
        XCTAssertEqual(y.host.squad.members.count, 2)
        XCTAssertEqual(y.host.peers.values.filter { $0 == ana }.count, 1, "a rejoin replaces the old link")

        // A link that goes away without a bye.
        y.host.peerClosed(y.peer("Ben"))
        XCTAssertNil(y.host.view.peer(of: ben))
        XCTAssertEqual(y.host.squad.members.count, 2, "still on the roster")

        // Removed: off the roster, and what the old link sends is ignored.
        y.send("Ana", .position(MemberPosition(at: origin, accuracy: 3, time: y.now)))
        y.command { $0.removeMember(ana, now: $1) }
        XCTAssertEqual(y.host.squad.members.map(\.id), [ben])
        XCTAssertNil(y.host.positions[ana])
        y.send("Ana", .checkFire(CheckFire(by: "Ana")))
        XCTAssertTrue(y.host.holds(now: y.now).isEmpty)

        // A contributor is for some other kind of host.
        y.join("Cam", role: .contributor)
        XCTAssertTrue(y.has("Cam") { if case .refused = $0 { return true }; return false })
    }

    func testOtherProtocolVersionsAreRefused() {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission(), joinCode: "RED234")
        let out = host.handle(SquadMessage(protocolVersion: SquadProtocol.version + 1, seq: 1,
                                           body: .hello(Hello(name: "Ana", device: UUID(), joinCode: "RED234"))),
                              from: PeerID("p"), now: Date())
        guard case .refused = out.first?.body else { return XCTFail("\(out)") }
        XCTAssertTrue(host.squad.members.isEmpty)
    }

    func testAnObserverWatchesButCantAct() throws {
        let y = Yard(mission: RallyMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        y.send("Ana", .position(MemberPosition(at: origin, accuracy: 3, time: y.now)))
        y.join("Watcher", role: .observer)
        let first = y.got["Watcher"] ?? []
        guard case let .observing(squad)? = first.first else { return XCTFail("\(first)") }
        XCTAssertEqual(squad.members.map(\.name), ["Ana"])
        XCTAssertEqual(first.dropFirst().first, .mission(MissionMessage(id: "test.rally", version: 1, payload: Data("hello observer".utf8))),
                       "the mission's welcome comes before the first status")
        XCTAssertTrue(first.contains { if case let .positions(r) = $0 { return r.positions.first?.member == ana }; return false },
                      "known positions on joining")

        // Nothing it sends acts on the squad.
        let before = (y.host.revision, y.host.mission.handled, y.host.positions)
        for body in Samples.all() {
            if case .hello = body { continue }
            if case .bye = body { continue }
            y.send("Watcher", body)
        }
        XCTAssertEqual(y.host.revision, before.0)
        XCTAssertEqual(y.host.mission.handled, before.1)
        XCTAssertEqual(y.host.positions, before.2)
        XCTAssertTrue(y.host.holds(now: y.now).isEmpty)
    }

    func testOrdersReachTheirMembersAndAnswersCount() throws {
        let y = Yard(mission: NoMission())
        let _ = try XCTUnwrap(y.join("Ana")), ben = try XCTUnwrap(y.join("Ben")), _ = try XCTUnwrap(y.join("Cy"))
        func orders(_ name: String) -> [Order] {
            y.got[name, default: []].compactMap { if case let .order(o) = $0 { return o } else { return nil } }
        }

        y.command { $0.sendOrder(.moveTo, text: "Left flank", at: origin, to: [ben], now: $1) }
        XCTAssertEqual(orders("Ben").map(\.text), ["Left flank"])
        XCTAssertTrue(orders("Ana").isEmpty && orders("Cy").isEmpty)

        y.command { $0.sendOrder(.holdPosition, text: "Hold", now: $1) }
        XCTAssertEqual(["Ana", "Ben", "Cy"].map { orders($0).count }, [1, 2, 1])

        // Answers: only from someone the order was for.
        let flank = orders("Ben")[0]
        y.send("Ben", .orderAck(OrderAck(order: flank.id, response: .done)))
        y.send("Cy", .orderAck(OrderAck(order: flank.id, response: .done)))
        XCTAssertEqual(y.host.acks[flank.id], [ben: .done])
        XCTAssertEqual(y.host.recipients(of: flank).map(\.name), ["Ben"])

        // A rejoin gets its unfinished orders again; a finished one isn't resent.
        y.got["Ben"] = []
        y.send("Ben", .bye)
        y.join("Ben")
        XCTAssertEqual(orders("Ben").map(\.kind), [.holdPosition])

        // An order to nobody on the roster is a problem; long text is cut.
        y.command { $0.sendOrder(.note, text: "x", to: [MemberID()], now: $1) }
        XCTAssertEqual(y.host.lastProblem, "Pick at least one member.")
        XCTAssertEqual(Order(kind: .note, text: String(repeating: "a", count: 500), time: Date()).text.count, Order.maxText)
        XCTAssertEqual(Order.Kind.core.compactMap(\.coreTitle).count, Order.Kind.core.count)
        XCTAssertNil(Order.Kind(rawValue: "test.rally.regroup").coreTitle)
    }

    func testNotesGoToTheLeaderAndOnToObservers() throws {
        let y = Yard(mission: NoMission())
        y.join("Ana")
        y.join("Watcher", role: .observer)
        let note = FieldNote(author: "someone else", time: y.now, text: "Mole hill")
        y.send("Ana", .note(note))
        XCTAssertEqual(y.host.notes.map(\.author), ["Ana"], "the author is the member, not what the note says")
        XCTAssertTrue(y.has("Watcher") { if case let .note(n) = $0 { return n.text == "Mole hill" && n.author == "Ana" }; return false })
        XCTAssertTrue(y.has("Ana") { if case let .receipt(r) = $0 { return r.id == note.id && r.status == .stored }; return false })
        XCTAssertNil(FieldNote(author: "a", time: y.now, text: "big", photo: Data(count: FieldNote.maxInlinePhotoBytes + 1)).photo)
        XCTAssertEqual(FileOffer(kind: .capture, group: UUID(), name: "../x", size: 1, sha256: "", field: nil).safeName, nil)
        XCTAssertEqual(FileOffer(kind: .capture, group: UUID(), name: "a.jpg", size: FileOffer.chunkBytes + 1, sha256: "", field: nil).chunkCount, 2)
        XCTAssertEqual(Data("abc".utf8).sha256Hex, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: Missions

    func testAMissionGetsItsOwnMessagesAndAddsHolds() throws {
        let y = Yard(mission: RallyMission())
        let ana = try XCTUnwrap(y.join("Ana")), ben = try XCTUnwrap(y.join("Ben"))
        y.command { core, now in core.run(now) { m, _ in m.rally = origin; return .changed() } }
        XCTAssertEqual(y.host.holds(now: y.now).map(\.kind).sorted(), ["notAtRally", "notAtRally"])

        y.send("Ana", .mission(MissionMessage(id: "test.rally", version: 1, payload: Data(#"{"arrived":true}"#.utf8))))
        XCTAssertEqual(y.host.mission.arrived, [ana])
        XCTAssertEqual(y.host.holds(now: y.now).map(\.member), [ben])

        // The mission's section of the status, in its own format.
        let status = try XCTUnwrap(y.lastStatus("Ben"))
        let section = try XCTUnwrap(status.mission("test.rally", version: 1))
        XCTAssertEqual(try SquadWire.decoder.decode(RallyMission.Status.self, from: section), .init(rally: origin, arrived: [ana]))
        XCTAssertNil(status.mission("test.rally", version: 2))

        // A bad payload is the mission's problem, not the link's.
        y.send("Ben", .mission(MissionMessage(id: "test.rally", version: 1, payload: Data("junk".utf8))))
        XCTAssertEqual(y.host.lastProblem, "Bad rally message.")
    }

    /// A phone running another mission, or a newer version of this one, still works as a member:
    /// its mission messages are ignored and nothing else is refused.
    func testOtherMissionsAndVersionsAreIgnoredNotRefused() throws {
        let y = Yard(mission: RallyMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        let revision = y.host.revision
        for m in [MissionMessage(id: "golf.firemission", version: 3, payload: Data("{}".utf8)),
                  MissionMessage(id: "test.rally", version: 2, payload: Data(#"{"arrived":true}"#.utf8))] {
            y.send("Ana", .mission(m))
        }
        XCTAssertEqual(y.host.mission.handled, 0)
        XCTAssertEqual(y.host.revision, revision)
        XCTAssertFalse(y.has("Ana") { if case .refused = $0 { return true }; return false })
        y.send("Ana", .position(MemberPosition(at: origin, accuracy: 3, time: y.now)))
        XCTAssertNotNil(y.host.positions[ana], "the core still works for it")

        // And the other way: a squad with no mission ignores every mission message.
        let plain = Yard(mission: NoMission())
        plain.join("Ana")
        let before = plain.host.revision
        plain.send("Ana", .mission(MissionMessage(id: "test.rally", version: 1, payload: Data(#"{"arrived":true}"#.utf8))))
        XCTAssertEqual(plain.host.revision, before)
    }

    /// Holds only add: a mission that returns no holds, or rewrites its own state, can't lift the
    /// core's.
    func testAMissionCantLiftACoreHold() throws {
        let y = Yard(mission: RallyMission())
        y.join("Ana")
        y.send("Ana", .checkFire(CheckFire(by: "Ana")))
        y.host.mission.hostile = true
        y.host.mission = RallyMission(hostile: true)
        y.command { core, now in core.run(now) { _, _ in MissionStep([], changed: true, clearsProblem: true) } }
        XCTAssertTrue(y.host.holds(now: y.now).contains(.checkFire(by: "Ana")))
        XCTAssertEqual(y.lastStatus("Ana")?.holds, [.checkFire(by: "Ana")])
    }

    /// Random traffic from phones (joined or not, an observer, well-formed or junk) never lifts a
    /// hold, whichever way the squad came to be held.
    func testMessageFuzzCantLiftAHold() throws {
        var g = SeededGenerator(seed: 0xF022)
        for scenario in 0..<3 {
            let y = Yard(mission: RallyMission())
            let ana = try XCTUnwrap(y.join("Ana"))
            y.join("Mal")
            y.join("Watcher", role: .observer)
            switch scenario {
            case 0: y.send("Ana", .checkFire(CheckFire(by: "Ana")))                     // check fire from a phone
            case 1: y.command { $0.callCheckFire(by: "Leader", now: $1) }               // check fire on the leader's device
            default: y.command { core, now in core.run(now) { m, _ in m.rally = origin; return .changed() } }   // a mission hold
            }
            // Mission holds can be satisfied by the member they're about; nothing lifts the rest.
            let pinned = y.host.holds(now: y.now).filter { $0.source == Hold.coreSource || $0.member == ana }
            XCTAssertFalse(pinned.isEmpty, "scenario \(scenario) starts held")

            let senders = ["Mal", "Watcher", "Stranger"]   // Ana stays quiet, so her hold must stand
            for _ in 0..<800 {
                let from = y.peer(senders[Int.random(in: 0..<senders.count, using: &g)])
                if Int.random(in: 0..<10, using: &g) == 0 {
                    var bytes = Data((0..<Int.random(in: 1..<40, using: &g)).map { _ in UInt8.random(in: 0...255, using: &g) })
                    if Bool.random(using: &g) { bytes.replaceSubrange(0..<min(4, bytes.count), with: [0, 0, 0, 20]) }
                    y.net.sendRaw(from: from, to: y.leader, bytes)
                } else {
                    var pick = Samples.all()
                    pick.append(.hello(Hello(name: "Mal", device: UUID(), joinCode: "RED234")))
                    pick.append(.mission(MissionMessage(id: "test.rally", version: 1, payload: Data(#"{"arrived":true}"#.utf8))))
                    pick.append(.mission(MissionMessage(id: "test.rally", version: 1, payload: Data(#"{"arrived":false}"#.utf8))))
                    y.net.send(from: from, [Outgoing(to: y.leader, pick[Int.random(in: 0..<pick.count, using: &g)])])
                }
                y.net.run()
                XCTAssertTrue(pinned.isSubset(of: y.host.holds(now: y.now)), "scenario \(scenario): a hold was lifted")
            }
        }
    }
}

private extension RallyMission {
    init(hostile: Bool) {
        self.init()
        self.hostile = hostile
    }
}
