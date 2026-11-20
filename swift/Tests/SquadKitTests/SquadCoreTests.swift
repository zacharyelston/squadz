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

    func testLeavingTakesAMemberOffTheSquadAndTellsEveryone() throws {
        let y = Yard(mission: NoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        let ben = try XCTUnwrap(y.join("Ben"))
        y.join("Watcher", role: .observer)
        func told(_ who: String, _ kind: Notice.Kind, about member: MemberID, _ text: String) -> Bool {
            y.has(who) { if case let .notice(n) = $0 { return n.kind == kind && n.member == member && n.text == text }; return false }
        }

        y.send("Ana", .position(MemberPosition(at: origin, accuracy: 3, time: y.now)))
        y.send("Ana", .leave)
        XCTAssertEqual(y.host.squad.members.map(\.id), [ben])
        XCTAssertNil(y.host.positions[ana])
        XCTAssertTrue(told("Ben", .left, about: ana, "Ana left the squad."))
        XCTAssertTrue(told("Watcher", .left, about: ana, "Ana left the squad."))
        XCTAssertEqual(y.lastStatus("Ben")?.squad.members.map(\.name), ["Ben"])
        XCTAssertEqual(y.host.notices.map(\.kind), [.left], "kept for the leader's own screen")
        XCTAssertEqual(y.host.credentials.first { $0.member == ana }?.revoked, true, "her credential is no use to anyone who finds it")

        // Closing the app is not leaving: still on the squad, and nobody is told.
        y.send("Ben", .bye)
        XCTAssertEqual(y.host.squad.members.map(\.id), [ben])
        XCTAssertEqual(y.host.notices.count, 1)

        // The leader removing someone tells the squad too. A notice from a phone does nothing.
        XCTAssertEqual(y.join("Ben"), ben)
        y.send("Ben", .notice(Notice(kind: .left, text: "The leader left the squad.", time: y.now)))
        XCTAssertEqual(y.host.notices.count, 1)
        y.command { $0.removeMember(ben, now: $1) }
        XCTAssertTrue(told("Watcher", .removed, about: ben, "Ben was removed from the squad."))
        XCTAssertTrue(y.host.squad.members.isEmpty)
    }

    func testASquadThatSharesNotesIsAChatRoom() throws {
        let y = Yard(mission: NoMission())
        y.host.sharesNotes = true
        y.join("Ana")
        y.join("Ben")
        func heard(_ who: String, _ text: String, from author: String) -> Bool {
            y.has(who) { if case let .note(n) = $0 { return n.text == text && n.author == author }; return false }
        }

        // Ana's note reaches Ben, under the name the leader knows her by, and comes back to her only as a receipt.
        let first = FieldNote(author: "Someone else", time: y.now, text: "At the gate")
        y.send("Ana", .note(first))
        XCTAssertTrue(heard("Ben", "At the gate", from: "Ana"))
        XCTAssertFalse(heard("Ana", "At the gate", from: "Ana"))
        XCTAssertTrue(y.has("Ana") { if case .receipt = $0 { return true }; return false })
        // The same note again changes nothing.
        y.send("Ana", .note(first))
        XCTAssertEqual(y.host.notes.count, 1)

        // The leader's own note reaches both.
        y.command { core, now in core.postNote(FieldNote(author: "Lead", time: now, text: "Hold there")) }
        XCTAssertTrue(heard("Ana", "Hold there", from: "Lead"))
        XCTAssertTrue(heard("Ben", "Hold there", from: "Lead"))

        // Someone who joins later reads up.
        y.join("Cy")
        XCTAssertTrue(heard("Cy", "At the gate", from: "Ana"))
        XCTAssertTrue(heard("Cy", "Hold there", from: "Lead"))

        // A squad that doesn't share notes keeps them with the leader.
        let quiet = Yard(mission: NoMission())
        quiet.join("Ana")
        quiet.join("Ben")
        quiet.send("Ana", .note(FieldNote(author: "Ana", time: quiet.now, text: "Just for the leader")))
        XCTAssertEqual(quiet.host.notes.count, 1)
        XCTAssertFalse(quiet.has("Ben") { if case .note = $0 { return true }; return false })
    }

    func testTheLeaderTakesAnOrderBack() throws {
        let y = Yard(mission: NoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        y.join("Ben")
        y.join("Watcher", role: .observer)
        func cancelled(_ who: String, _ id: UUID) -> Bool { y.has(who) { $0 == .orderCancel(id) } }

        y.command { $0.sendOrder(.moveTo, text: "To the oak", at: origin, to: [ana], now: $1) }
        let order = try XCTUnwrap(y.host.orders.last)
        y.command { $0.cancelOrder(order.id, now: $1) }
        XCTAssertTrue(cancelled("Ana", order.id))
        XCTAssertTrue(cancelled("Watcher", order.id))
        XCTAssertFalse(cancelled("Ben", order.id), "it wasn't for him")
        XCTAssertEqual(y.host.cancelled, [order.id])
        XCTAssertEqual(y.host.orders.map(\.id), [order.id], "kept, for the record")

        // An answer that was already on its way counts for nothing, and cancelling twice says nothing more.
        y.send("Ana", .orderAck(OrderAck(order: order.id, response: .done)))
        XCTAssertNil(y.host.acks[order.id]?[ana])
        XCTAssertTrue(y.host.cancelOrder(order.id, now: y.now).isEmpty)
        XCTAssertTrue(y.host.cancelOrder(UUID(), now: y.now).isEmpty)

        // Ana was away for the next one being taken back: she hears when she is back, and isn't sent the order again.
        y.command { $0.sendOrder(.holdPosition, text: "By the gate", to: [ana], now: $1) }
        let second = try XCTUnwrap(y.host.orders.last)
        y.host.peerClosed(y.peer("Ana"))
        y.command { $0.cancelOrder(second.id, now: $1) }
        y.got["Ana"] = []
        XCTAssertEqual(y.join("Ana"), ana)
        XCTAssertTrue(cancelled("Ana", second.id))
        XCTAssertFalse(y.has("Ana") { if case .order = $0 { return true }; return false })

        // A phone can't take an order back.
        y.command { $0.sendOrder(.note, text: "Back by five", now: $1) }
        let third = try XCTUnwrap(y.host.orders.last)
        y.send("Ana", .orderCancel(third.id))
        XCTAssertFalse(y.host.cancelled.contains(third.id))
    }

    func testJoinCodesRejoinAndRemoval() throws {
        let y = Yard(mission: NoMission())
        // A link the transport hasn't vouched for can't join.
        y.net.add(y.peer("Eve")) { [unowned y] m, _ in y.got["Eve", default: []].append(m.body); return [] }
        y.send("Eve", .hello(EnrolmentRequest(name: "Eve", device: UUID()).hello))
        XCTAssertTrue(y.has("Eve") { if case .refused = $0 { return true }; return false })
        XCTAssertTrue(y.host.squad.members.isEmpty)
        XCTAssertTrue(y.host.credentials.isEmpty)

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
        XCTAssertTrue(y.has("Ana") { $0 == .refused("Removed from the squad.") })
        y.send("Ana", .checkFire(CheckFire(by: "Ana")))
        XCTAssertTrue(y.host.holds(now: y.now).isEmpty)
        // And the credential no longer opens a link.
        XCTAssertNil(y.host.view.peer(of: ana))
        y.join("Ana")
        XCTAssertEqual(y.host.squad.members.map(\.id), [ben])
        XCTAssertFalse(y.host.linkKeys(now: y.now).contains(y.credentials["Ana"]!.linkKey))

        // A contributor is for some other kind of host.
        y.join("Cam", role: .contributor)
        XCTAssertTrue(y.has("Cam") { if case .refused = $0 { return true }; return false })
    }

    func testMembersSeeEachOtherOnlyWhenTheLeaderSharesPositions() throws {
        func positions(_ y: Yard<NoMission>, _ name: String) -> [MemberID] {
            y.got[name, default: []].flatMap { body -> [MemberID] in
                if case let .positions(r) = body { return r.positions.compactMap(\.member) } else { return [] }
            }
        }
        let quiet = Yard(mission: NoMission())
        quiet.join("Ana"); quiet.join("Ben")
        quiet.send("Ana", .position(MemberPosition(at: origin, accuracy: 3, time: quiet.now)))
        XCTAssertTrue(positions(quiet, "Ben").isEmpty)

        let y = Yard(mission: NoMission())
        y.host.sharesPositions = true
        let ana = try XCTUnwrap(y.join("Ana")), ben = try XCTUnwrap(y.join("Ben"))
        y.send("Ana", .position(MemberPosition(member: ben, at: origin, accuracy: 3, time: y.now)))
        XCTAssertEqual(positions(y, "Ben"), [ana], "from Ana's link, so it is Ana's, whatever it says")
        XCTAssertTrue(positions(y, "Ana").isEmpty, "not echoed to the sender")
        // Someone who connects later gets what is already known, except their own.
        y.send("Ben", .position(MemberPosition(at: origin, accuracy: 3, time: y.now)))
        let cy = try XCTUnwrap(y.join("Cy"))
        XCTAssertEqual(Set(positions(y, "Cy")), [ana, ben])
        y.send("Cy", .bye)
        y.got["Cy"] = []
        y.send("Cy", .position(MemberPosition(at: origin, accuracy: 3, time: y.now)))   // not connected: ignored
        XCTAssertNil(y.host.positions[cy])
    }

    func testOtherProtocolVersionsAreRefused() {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let out = host.handle(SquadMessage(protocolVersion: SquadProtocol.version + 1, seq: 1,
                                           body: .hello(Hello(name: "Ana", device: UUID()))),
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
                    pick.append(.hello(EnrolmentRequest(name: "Mal", device: UUID()).hello))
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
