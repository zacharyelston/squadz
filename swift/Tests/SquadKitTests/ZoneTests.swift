import CoreGeo
import XCTest
@testable import SquadKit

final class ZoneTests: XCTestCase {
    func testZonesCrossingsAudienceAndReconnectTravelInStatus() throws {
        let yard = Yard(mission: NoMission())
        let ben = try XCTUnwrap(yard.join("Ben"))
        let ana = try XCTUnwrap(yard.join("Ana"))
        let goal = SquadZone(name: "Rally", shape: .circle(center: origin, radius: 100), rule: .goal, members: [ben])
        yard.command { $0.setZones([goal], now: $1) }
        XCTAssertEqual(yard.lastStatus("Ana")?.zones, [goal])
        for (index,east) in [150.0,150,0,0].enumerated() {
            yard.now = yard.now.addingTimeInterval(10)
            // The transport's authenticated member overrides a forged payload member.
            yard.send("Ben", .position(MemberPosition(member: ana, at: Geo.offset(origin,east:east,north:0),accuracy:3,time:yard.now)))
            yard.send("Ana", .position(MemberPosition(at: Geo.offset(origin,east:east,north:0),accuracy:3,time:yard.now)))
            if index < 3 { XCTAssertTrue(yard.host.zoneEvents.isEmpty) }
        }
        let event = try XCTUnwrap(yard.host.zoneEvents.first)
        XCTAssertEqual(event.member,ben)
        XCTAssertEqual(event.kind,.arrived)
        XCTAssertEqual(yard.lastStatus("Ana")?.zoneEvents?.first,event)
        yard.host.peerClosed(yard.peer("Ben"))
        yard.join("Ben")
        XCTAssertEqual(yard.lastStatus("Ben")?.zoneEvents,[event])
        XCTAssertEqual(yard.host.orders.count,0,"Arrival never invents or completes an order")
    }

    func testMemberCannotSetZonesAndInvalidUpdatePreservesDefinitions() throws {
        let yard = Yard(mission: NoMission()); _ = yard.join("Ben")
        let zone = SquadZone(name:"Boundary",shape:.circle(center:origin,radius:200),rule:.allowedArea)
        yard.command { $0.setZones([zone],now:$1) }
        var forged = yard.host.status(now:yard.now); forged.zones=[]
        yard.send("Ben",.status(forged))
        XCTAssertEqual(yard.host.zones,[zone])
        var invalid=zone;invalid.name=" "
        yard.command { $0.setZones([invalid],now:$1) }
        XCTAssertEqual(yard.host.zones,[zone])
        yard.command { $0.setZones([zone,zone],now:$1) }
        XCTAssertEqual(yard.host.zones,[zone])
    }

    func testOlderStatusDecodesWithoutZoneFieldsAndNewStatusRoundTrips() throws {
        let squad=Squad(name:"Old")
        let old=SquadStatus(revision:1,squad:squad,holds:[])
        let data=try JSONEncoder().encode(old)
        XCTAssertNil(try JSONDecoder().decode(SquadStatus.self,from:data).zones)
        var updated=old
        updated.zones=[SquadZone(name:"Rally",shape:.circle(center:origin,radius:100),rule:.goal)]
        updated.zoneEvents=[]
        XCTAssertEqual(try JSONDecoder().decode(SquadStatus.self,from:JSONEncoder().encode(updated)),updated)
    }
}
