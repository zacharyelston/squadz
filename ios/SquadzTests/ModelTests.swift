import CoreGeo
import Network
import SquadKit
import SquadLink
import XCTest
@testable import Squadz

/// Two app models in one process, a leader and a member, talking over real sockets on loopback.
@MainActor
final class ModelTests: XCTestCase {
    private var made: [(UserDefaults, String, URL, String)] = []

    private func model(_ label: String) -> AppModel {
        let suite = "squadz.tests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(label, forKey: "displayName")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        made.append((defaults, suite, folder, suite))
        return AppModel(defaults: defaults, keychainService: suite, folder: folder, advertise: false)
    }

    private func again(_ index: Int) -> AppModel {
        let (defaults, _, folder, keychain) = made[index]
        return AppModel(defaults: defaults, keychainService: keychain, folder: folder, advertise: false)
    }

    override func tearDown() async throws {
        for (defaults, suite, folder, _) in made {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        made = []
    }

    private func wait(_ what: String, timeout: TimeInterval = 15, until done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !done() {
            if Date() > end { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func point(to leader: AppModel, _ member: AppModel) {
        member.fixedEndpoint = { [weak leader] in
            leader?.hostPort.flatMap { NWEndpoint.Port(rawValue: $0) }.map { .hostPort(host: "127.0.0.1", port: $0) }
        }
    }

    func testLeadJoinSeeEachOtherRemove() async throws {
        let ana = model("Ana"), ben = model("Ben")
        ana.startSquad(name: "Red", as: "Ana")
        XCTAssertEqual(ana.role, .leader)
        try await wait("the leader's link") { ana.hostPort != nil }
        point(to: ana, ben)

        // Ben reads the invite the way a scan delivers it: as text. Nothing joins yet.
        ana.openJoining()
        let shown = try XCTUnwrap(ana.invite).url(scheme: "squadz").absoluteString
        try await Task.sleep(for: .milliseconds(300))   // the link takes the invite's key
        ben.offer(shown)
        let offered = try XCTUnwrap(ben.offered)
        XCTAssertEqual(offered.name, "Red")
        XCTAssertEqual(offered.by, "Ana")
        XCTAssertEqual(ben.role, .none)
        XCTAssertEqual(ana.squad?.members.count, 1)

        ben.join(offered, as: "Ben")
        try await wait("Ben on both rosters") {
            ben.role == .member && ben.linkProblem == nil && ben.squad?.members.count == 2 && ana.squad?.members.count == 2
        }
        XCTAssertEqual(ben.leaderID, ana.me)
        XCTAssertEqual(ben.located.map(\.member.name), ["Ana", "Ben"])

        // Each sees where the other is.
        let t = Date()
        ana.setMyPosition(MemberPosition(at: GeoPoint(latitude: 42.36, longitude: -71.06), accuracy: 5, time: t), member: try XCTUnwrap(ana.me))
        ben.setMyPosition(MemberPosition(at: GeoPoint(latitude: 42.37, longitude: -71.05), accuracy: 5, time: t), member: try XCTUnwrap(ben.me))
        try await wait("positions both ways") { ana.positions.count == 2 && ben.positions.count == 2 }
        XCTAssertEqual(ben.positions[try XCTUnwrap(ana.me)]?.at.latitude, 42.36)
        XCTAssertEqual(ana.positions[try XCTUnwrap(ben.me)]?.at.latitude, 42.37)
        XCTAssertFalse(ana.located[1].isStale(now: t.addingTimeInterval(60)))
        XCTAssertTrue(ana.located[1].isStale(now: t.addingTimeInterval(121)))

        // Ben's phone restarts: it comes back with what it kept, without an invite.
        ana.closeJoining()
        let benAgain = again(1)
        point(to: ana, benAgain)
        ben.fixedEndpoint = nil
        benAgain.resume()
        try await wait("Ben back") { benAgain.role == .member && benAgain.linkProblem == nil && benAgain.squad?.members.count == 2 }
        XCTAssertEqual(benAgain.me, ben.me)

        // The leader removes Ben: his phone is told, and forgets the squad.
        ana.remove(try XCTUnwrap(benAgain.me))
        try await wait("Ben removed") { benAgain.role == .none && ana.squad?.members.count == 1 }
        XCTAssertEqual(benAgain.alert, "Removed from the squad.")
        let third = again(1)
        third.resume()
        XCTAssertEqual(third.role, .none, "nothing kept to come back with")
        ana.endSquad()
    }

    func testALeaderPicksUpItsSquadAfterARestart() async throws {
        let ana = model("Ana"), ben = model("Ben")
        ana.startSquad(name: "Red", as: "Ana")
        try await wait("the leader's link") { ana.hostPort != nil }
        point(to: ana, ben)
        ana.openJoining()
        try await Task.sleep(for: .milliseconds(300))
        ben.offer(try XCTUnwrap(ana.invite).url(scheme: "squadz").absoluteString)
        ben.join(try XCTUnwrap(ben.offered), as: "Ben")
        try await wait("Ben in") { ben.linkProblem == nil && ben.squad?.members.count == 2 }
        let squad = try XCTUnwrap(ana.squad)

        // The leader's app is closed and opened again, on a new port.
        let anaAgain = again(0)
        anaAgain.resume()
        XCTAssertEqual(anaAgain.role, .leader)
        XCTAssertEqual(anaAgain.squad, squad)
        XCTAssertEqual(anaAgain.me, ana.me)
        XCTAssertNil(anaAgain.invite, "joining doesn't reopen by itself")
        try await wait("the new link") { anaAgain.hostPort != nil }

        // Ben's credential still works with it.
        let benAgain = again(1)
        point(to: anaAgain, benAgain)
        benAgain.resume()
        try await wait("Ben linked to the restarted leader") { benAgain.linkProblem == nil && benAgain.squad?.members.count == 2 }
        anaAgain.endSquad()
        XCTAssertEqual(again(0).role, .none)
    }

    func testThingsThatArentInvitesAreTurnedDown() throws {
        let ben = model("Ben")
        for text in ["hello", "https://example.com/join?v=1", "squadz://pair?c=abc", "squadz://join?v=1&squad=x"] {
            ben.offer(text)
            XCTAssertNil(ben.offered, text)
            XCTAssertEqual(ben.alert, "That isn't a Squadz invite.")
            ben.alert = nil
        }
        var core = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let old = core.openJoining(now: Date().addingTimeInterval(-3600))
        ben.offer(old.url(scheme: "squadz").absoluteString)
        XCTAssertNil(ben.offered)
        XCTAssertEqual(ben.alert, "This invite has expired. Ask for a new one.")
    }
}
