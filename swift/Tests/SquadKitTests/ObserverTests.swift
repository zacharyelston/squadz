import CoreGeo
import XCTest
@testable import SquadKit

final class ObserverTests: XCTestCase {
    func testObserverGetsExistingOrdersNotesAnswersAndVisibleRoster() throws {
        let yard = Yard(mission: NoMission())
        let ben = try XCTUnwrap(yard.join("Ben"))
        yard.command { $0.sendOrder(.moveTo, text: "Rally", at: origin, to: [ben], now: $1) }
        let order = try XCTUnwrap(yard.host.orders.last)
        yard.send("Ben", .orderAck(OrderAck(order: order.id, response: .seen)))
        yard.command { $0.postNote(FieldNote(author: "Leader", time: $1, text: "Existing note")) }
        _ = yard.join("Desk", role: .observer)
        XCTAssertTrue(yard.has("Desk") { if case let .order(value) = $0 { return value.id == order.id }; return false })
        XCTAssertTrue(yard.has("Desk") { if case let .note(value) = $0 { return value.text == "Existing note" }; return false })
        let status = try XCTUnwrap(yard.lastStatus("Desk"))
        XCTAssertEqual(status.observerState?.answers.first?.response, .seen)
        XCTAssertEqual(status.observers?.first?.name, "Desk")
        XCTAssertEqual(status.observers?.first?.connected, true)
        XCTAssertNil(yard.lastStatus("Ben")?.observerState, "Personal-order answers are not broadcast to ordinary members")
        XCTAssertFalse(yard.host.squad.members.contains { $0.name == "Desk" })
        yard.send("Ben", .orderAck(OrderAck(order: order.id, response: .done)))
        XCTAssertEqual(yard.lastStatus("Desk")?.observerState?.answers.first?.response, .done)
    }
    func testObserverCannotActAndLeaderCanRemoveIt() throws {
        let yard = Yard(mission: NoMission()); let ben = try XCTUnwrap(yard.join("Ben"))
        _ = yard.join("Desk", role: .observer)
        yard.command { $0.sendOrder(.holdPosition, text: "Wait", now: $1) }
        let order = try XCTUnwrap(yard.host.orders.last)
        for body in [SquadMessage.Body.position(MemberPosition(member: ben, at: origin, accuracy: 5, time: yard.now)),
                     .note(FieldNote(author: "Desk", time: yard.now, text: "Injected")), .orderAck(OrderAck(order: order.id, response: .done)),
                     .checkFire(CheckFire(by: "Desk")), .status(yard.host.status(now: yard.now))] { yard.send("Desk", body) }
        XCTAssertTrue(yard.host.notes.isEmpty); XCTAssertTrue(yard.host.positions.isEmpty); XCTAssertTrue(yard.host.acks.isEmpty)
        XCTAssertNil(yard.host.activeCheckFire)
        let credential = try XCTUnwrap(yard.credentials["Desk"])
        yard.command { $0.revoke(credential: credential.id, now: $1) }
        XCTAssertTrue(yard.host.observerRoster.isEmpty)
        XCTAssertTrue(yard.lastStatus("Ben")?.observers?.isEmpty == true)
        XCTAssertTrue(yard.has("Desk") { $0 == .refused("Removed from the squad.") })
    }
    func testDisconnectAndReconnectShowCurrentPresenceAndDoNotSpendMemberSlot() throws {
        let yard = Yard(mission: NoMission()); let ben = try XCTUnwrap(yard.join("Ben")); _ = yard.join("Desk", role: .observer)
        yard.command { core, _ in core.peerClosed(yard.peer("Ben")) }
        XCTAssertEqual(yard.lastStatus("Desk")?.observerState?.connections.first(where: { $0.member == ben })?.connected, false)
        _ = yard.join("Ben")
        XCTAssertEqual(yard.lastStatus("Desk")?.observerState?.connections.first(where: { $0.member == ben })?.connected, true)
        yard.command { core, _ in core.peerClosed(yard.peer("Desk")) }
        XCTAssertEqual(yard.host.observerRoster.first?.connected, false)
        _ = yard.join("Desk")
        XCTAssertEqual(yard.host.observerRoster.count, 1)
        XCTAssertEqual(yard.host.observerRoster.first?.connected, true)
        XCTAssertEqual(yard.host.squad.members.count, 1)
    }
}
