import CoreLocation
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

    func testFailedEnrollmentSaveKeepsLastRosterAndAllowsRetry() async throws {
        let leader = model("Leader"), member = model("Member")
        leader.startSquad(name: "Red", as: "Leader")
        try await wait("leader listening") { leader.hostPort != nil }
        leader.openJoining()
        let invite = try XCTUnwrap(leader.invite)
        try await wait("listener with invite key") { leader.hostIsListening }
        let folder = made[0].2
        let backup = folder.appendingPathExtension("backup")
        let files = FileManager.default
        try files.moveItem(at: folder, to: backup)
        defer { try? files.removeItem(at: backup) }
        try Data().write(to: folder) // A file in place of the parent directory makes writes fail.
        point(to: leader, member)
        member.join(invite, as: "Member")
        try await wait("leader reporting the write failure") { leader.alert != nil }
        XCTAssertEqual(leader.squad?.members.count, 1)
        XCTAssertEqual(member.role, .none)
        try files.removeItem(at: folder)
        try files.moveItem(at: backup, to: folder)
        let saved = folder.appendingPathComponent("leading.json")
        XCTAssertEqual(try JSONDecoder().decode(LeaderSaved.self, from: Data(contentsOf: saved)).squad.members.count, 1)

        try await wait("member receiving refusal") { !member.joining && member.alert != nil }
        XCTAssertEqual(member.role, .none)
        member.join(invite, as: "Member")
        try await wait("durable enrollment") { member.role == .member && leader.squad?.members.count == 2 }
        XCTAssertEqual(try JSONDecoder().decode(LeaderSaved.self, from: Data(contentsOf: saved)).squad, leader.squad)
        leader.endSquad()
    }

    func testLocationStreamCanRestartAfterErrorAndCompletion() async throws {
        var runs = 0
        let fix = CLLocation(latitude: 10, longitude: 20)
        let tracker = LocationTracker { receive in
            runs += 1
            receive(fix)
            if runs == 1 { throw CancellationError() }
        }
        for expected in 1...3 {
            tracker.start()
            try await wait("location stream run") { runs == expected }
            XCTAssertEqual(tracker.latest(now: .distantFuture)?.time, fix.timestamp)
        }
        tracker.stop()
    }

    func testStoppedLocationStreamCannotClearReplacement() async throws {
        var pending: [CheckedContinuation<Void, Never>] = []
        let tracker = LocationTracker { _ in
            await withCheckedContinuation { pending.append($0) }
        }
        tracker.start()
        try await wait("first stream") { pending.count == 1 }
        tracker.stop()
        tracker.start()
        try await wait("replacement stream") { pending.count == 2 }
        pending[0].resume()
        await Task.yield()
        tracker.start()
        await Task.yield()
        XCTAssertEqual(pending.count, 2)
        tracker.stop()
        for continuation in pending.dropFirst() { continuation.resume() }
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
        try await wait("listener with invite key") { ana.hostIsListening }
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

    func testTheLeaderSendsAMemberSomewhereAndHearsBack() async throws {
        let ana = model("Ana"), ben = model("Ben")
        ana.startSquad(name: "Red", as: "Ana")
        try await wait("the leader's link") { ana.hostPort != nil }
        point(to: ana, ben)
        ana.openJoining()
        let shown = try XCTUnwrap(ana.invite).url(scheme: "squadz").absoluteString
        try await wait("listener with invite key") { ana.hostIsListening }
        ben.offer(shown)
        ben.join(try XCTUnwrap(ben.offered), as: "Ben")
        try await wait("Ben in") { ben.role == .member && ben.linkProblem == nil && ana.squad?.members.count == 2 }
        let benID = try XCTUnwrap(ben.me)

        // Not sent: a move-to with no place, a note with no words, and anything from a member.
        XCTAssertFalse(ana.sendOrder(.moveTo, text: "The oak"))
        XCTAssertFalse(ana.sendOrder(.note, text: "  "))
        XCTAssertFalse(ben.sendOrder(.holdPosition, text: ""))
        XCTAssertTrue(ana.orders.isEmpty)

        let oak = GeoPoint(latitude: 42.361, longitude: -71.061)
        XCTAssertTrue(ana.sendOrder(.moveTo, text: "The oak", at: oak, to: [benID]))
        try await wait("Ben has the order") { ben.orders.count == 1 }
        let order = try XCTUnwrap(ben.orders.first)
        XCTAssertEqual(order.title, "Move to")
        XCTAssertEqual(order.at, oak)
        XCTAssertEqual(ben.openOrders.map(\.id), [order.id])
        XCTAssertEqual(ana.recipients(of: order).map(\.name), ["Ben"], "the leader isn't asked to answer its own order")
        XCTAssertEqual(OrdersPanel.answers(to: order, from: ana.recipients(of: order), given: ana.answers[order.id] ?? [:]), "Ben: no answer yet")
        XCTAssertFalse(ana.isSettled(order))

        // Seen keeps it open on both; Done settles it on both.
        ben.answer(order, .seen)
        try await wait("the leader sees Seen") { ana.answers[order.id]?[benID] == .seen }
        XCTAssertEqual(ben.openOrders.count, 1)
        XCTAssertEqual(ana.openOrders.count, 1)
        ben.answer(order, .done)
        try await wait("the leader sees Done") { ana.answers[order.id]?[benID] == .done }
        XCTAssertTrue(ben.openOrders.isEmpty)
        XCTAssertTrue(ana.openOrders.isEmpty)
        XCTAssertEqual(OrdersPanel.answers(to: order, from: ana.recipients(of: order), given: ana.answers[order.id] ?? [:]), "Ben: Done")

        // To the whole squad, newest first on both.
        XCTAssertTrue(ana.sendOrder(.note, text: "Back by five"))
        try await wait("Ben has the note") { ben.orders.count == 2 }
        XCTAssertEqual(ben.orders.first?.text, "Back by five")
        XCTAssertEqual(ana.orders.first?.text, "Back by five")
        // Two more wait in the order they came: the oldest is the one to do next.
        XCTAssertTrue(ana.sendOrder(.holdPosition, text: "By the gate"))
        try await wait("Ben has three") { ben.orders.count == 3 }
        XCTAssertEqual(ben.queue.map(\.text), ["Back by five", "By the gate"])
        ben.answer(try XCTUnwrap(ben.queue.first), .done)
        XCTAssertEqual(ben.queue.map(\.text), ["By the gate"])
        ben.answer(try XCTUnwrap(ben.queue.first), .cannot)
        XCTAssertTrue(ben.queue.isEmpty)
        XCTAssertEqual(ben.orders.count, 3, "answered orders stay in the list")
        try await wait("the leader sees Can't") { ana.openOrders.isEmpty }
        ana.endSquad()
    }

    func testALeaderPicksUpItsSquadAfterARestart() async throws {
        let ana = model("Ana"), ben = model("Ben")
        ana.startSquad(name: "Red", as: "Ana")
        try await wait("the leader's link") { ana.hostPort != nil }
        point(to: ana, ben)
        ana.openJoining()
        try await wait("listener with invite key") { ana.hostIsListening }
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

    func testAMembersDetailLine() {
        XCTAssertEqual([0, 44, 46, 90, 181, 270, 337, 338, -45].map(MemberList.compass), ["N", "NE", "NE", "E", "S", "W", "NW", "N", "NW"])

        let here = GeoPoint(latitude: 44.05, longitude: -121.31)
        let ana = Member(id: MemberID(), name: "Ana", device: UUID(), role: .member)
        let position = MemberPosition(at: Geo.destination(here, bearing: 90, distance: 500), accuracy: 5, time: .now)
        let joined = Date(timeIntervalSince1970: 1_800_000_000)

        // On the leader's device: the link first, then where, then when she joined.
        let seen = MemberList.details(Located(member: ana, position: position, isMe: false, isLeader: false, link: .relay, joined: joined), from: here)
        XCTAssertEqual(seen.count, 5, "\(seen)")
        XCTAssertEqual(seen.first, "Connected through the relay")
        XCTAssertTrue(seen[1].hasSuffix(" E of you"), seen[1])
        XCTAssertTrue(seen[2].hasPrefix("±"), seen[2])
        XCTAssertEqual(seen[3], String(format: "%.5f, %.5f", position.at.latitude, position.at.longitude))
        XCTAssertTrue(seen[4].hasPrefix("joined "), seen[4])

        // On a member's phone the link and the joining time aren't known, and nobody is a distance from themselves.
        XCTAssertEqual(MemberList.details(Located(member: ana, position: position, isMe: true, isLeader: false), from: position.at).count, 2)
        XCTAssertEqual(MemberList.details(Located(member: ana, position: nil, isMe: false, isLeader: false, link: .away), from: here), ["Not connected"])
        XCTAssertEqual(MemberList.details(Located(member: ana, position: nil, isMe: false, isLeader: false), from: nil), [])

        // The leader chooses which of these the list shows.
        let all = Located(member: ana, position: position, isMe: false, isLeader: false, link: .direct, joined: joined)
        XCTAssertEqual(MemberList.details(all, from: here, showing: [.link]), ["Connected"])
        XCTAssertEqual(MemberList.details(all, from: here, showing: [.coordinates, .link]).count, 2)
        XCTAssertEqual(MemberList.details(all, from: here, showing: []), [])
        XCTAssertEqual(MemberDetail.chosen(MemberDetail.everything), Set(MemberDetail.allCases))
        XCTAssertEqual(MemberDetail.stored([.joined, .link]), "link,joined")
        XCTAssertEqual(MemberDetail.chosen("link,nonsense,,joined"), [.link, .joined])
        XCTAssertEqual(MemberDetail.chosen(""), [])
    }
}
