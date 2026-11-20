import AVFoundation
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

    func testLeaderCanSeeAndRemoveAReadOnlyObserver() async throws {
        let leader = model("Leader")
        leader.startSquad(name: "Theater test", as: "Leader")
        defer { leader.endSquad() }
        try await wait("leader listening") { leader.hostPort != nil }
        leader.openJoining()
        try await wait("invite listener") { leader.hostIsListening }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(leader.hostPort))!)
        let enroller = SquadEnroller(invite: try XCTUnwrap(leader.invite), name: "Theater desk", device: UUID(), role: .observer)
        enroller.fixedEndpoint = endpoint
        var credential: MemberCredential?
        enroller.onDone = { result in if case let .success(value) = result { credential = value } }
        enroller.start()
        defer { enroller.cancel() }
        try await wait("observer credential") { credential != nil }
        let client = SquadLinkClient(credential: try XCTUnwrap(credential), name: "Theater desk", device: UUID())
        client.fixedEndpoint = endpoint
        var refused = false
        client.onStatus = { if case .stopped = $0 { refused = true } }
        client.start()
        defer { client.stop() }
        try await wait("visible watcher") { leader.watchingObservers.first?.connected == true }
        XCTAssertEqual(leader.watchingObservers.first?.name, "Theater desk")
        XCTAssertEqual(leader.squad?.members.count, 1, "An observer is separate from squad members")
        client.send(.note(FieldNote(author: "Theater", time: .now, text: "Should be ignored")))
        client.send(.checkFire(CheckFire(by: "Theater")))
        var gotLeaderNote = false
        client.onMessage = { if case let .note(note) = $0.body, note.text == "Observation only" { gotLeaderNote = true } }
        XCTAssertTrue(leader.sendNote("Observation only"))
        try await wait("observer receives leader note") { gotLeaderNote }
        XCTAssertEqual(leader.notes.map(\.text), ["Observation only"])
        leader.removeObserver(try XCTUnwrap(leader.watchingObservers.first))
        try await wait("watcher removed") { leader.watchingObservers.isEmpty && refused }
    }

    func testZoneDefinitionsAndAlertsSyncAndSurviveLeaderRestart() async throws {
        let leader = model("Leader"), member = model("Ben")
        leader.startSquad(name: "Zones", as: "Leader")
        XCTAssertEqual(leader.role, .leader, leader.alert ?? "Could not lead")
        try await wait("leader listening") { leader.hostPort != nil }
        leader.openJoining()
        try await wait("listener with invite key") { leader.hostIsListening }
        point(to: leader, member)
        member.join(try XCTUnwrap(leader.invite), as: "Ben")
        try await wait("member joined") { member.role == .member && leader.squad?.members.count == 2 }
        let ben = try XCTUnwrap(member.me)
        let center = GeoPoint(latitude: 42.36, longitude: -71.06)
        let zone = SquadZone(name: "Rally", shape: .circle(center: center, radius: 100), rule: .goal, members: [ben])
        XCTAssertTrue(leader.saveZone(zone))
        try await wait("zone received") { member.zones == [zone] }
        XCTAssertFalse(member.saveZone(zone), "A member cannot edit zones")
        let base = Date.now
        for (index, east) in [150.0, 150, 0, 0].enumerated() {
            let time = base.addingTimeInterval(Double(index))
            member.setMyPosition(MemberPosition(at: Geo.offset(center, east: east, north: 0), accuracy: 3, time: time), member: ben)
            try await wait("position received") { leader.positions[ben].map { abs($0.time.timeIntervalSince(time)) < 0.001 } == true }
        }
        try await wait("arrival delivered") { leader.zoneEvents.count == 1 && member.zoneEvents.count == 1 }
        XCTAssertEqual(member.zoneEvents.first?.kind, .arrived)
        XCTAssertEqual(leader.zoneAlert?.id, member.zoneAlert?.id)
        XCTAssertTrue(member.orders.isEmpty)
        let mission = try XCTUnwrap(leader.missionID)
        XCTAssertEqual(leader.logs.entries(of: mission).filter { $0.kind == .zoneArrival }.count, 1)
        let corners = [(-100.0, -100.0), (100.0, -100.0), (100.0, 100.0), (-100.0, 100.0)]
            .map { Geo.offset(center, east: $0.0, north: $0.1) }
        let allowed = SquadZone(name: "Search area", shape: .polygon(vertices: corners), rule: .allowedArea, members: [ben])
        XCTAssertTrue(leader.saveZone(allowed))
        try await wait("polygon received") { member.zones.count == 2 }
        for (index, east) in [0.0, 0, 150, 150].enumerated() {
            let time = base.addingTimeInterval(Double(index + 4))
            member.setMyPosition(MemberPosition(at: Geo.offset(center, east: east, north: 0), accuracy: 3, time: time), member: ben)
            try await wait("boundary position received") { leader.positions[ben].map { abs($0.time.timeIntervalSince(time)) < 0.001 } == true }
        }
        try await wait("departure delivered") { member.zoneEvents.count == 2 }
        XCTAssertEqual(member.zoneEvents.last?.kind, .left)
        XCTAssertEqual(leader.logs.entries(of: mission).filter { $0.kind == .zoneDeparture }.count, 1)
        let restored = again(0)
        restored.resume()
        XCTAssertEqual(restored.zones, [zone, allowed])
        XCTAssertEqual(restored.zoneEvents, leader.zoneEvents)
        XCTAssertNil(restored.zoneAlert, "Historical events must not announce again on restart")
        XCTAssertEqual(restored.logs.entries(of: mission).filter { $0.kind == .zoneArrival || $0.kind == .zoneDeparture }.count, 2,
                       "Restarting must not duplicate historical zone crossings in the mission log")
        restored.endSquad()
        leader.endSquad()
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

        // The leader's update rate reaches a member who is already in, and one who joins later gets it too.
        XCTAssertEqual(ben.reportEvery, 10)
        ana.setReportEvery(2)
        try await wait("Ben follows the leader's rate") { ben.reportEvery == 2 }
        XCTAssertEqual(ana.reportEvery, 2)
        ben.setReportEvery(60)
        XCTAssertEqual(ben.reportEvery, 2, "only the leader sets it")

        // Field notes are a chat: each sees the other's, under the name the leader knows them by.
        XCTAssertFalse(ben.sendNote("   "))
        XCTAssertTrue(ben.sendNote("At the gate"))
        try await wait("the leader has Ben's note") { ana.notes.count == 1 }
        XCTAssertEqual(ana.notes.first?.author, "Ben")
        XCTAssertEqual(ana.unreadNotes, 1)
        XCTAssertEqual(ben.unreadNotes, 0, "his own")
        XCTAssertTrue(ana.sendNote("Hold there"))
        try await wait("Ben has the leader's note") { ben.notes.count == 2 }
        XCTAssertEqual(ben.notes.map(\.text), ["At the gate", "Hold there"])
        XCTAssertEqual(ben.notes.map(ben.isMine), [true, false])
        XCTAssertEqual(ana.notes.map(ana.isMine), [false, true])
        XCTAssertEqual(ben.unreadNotes, 1)
        ben.markNotesRead()
        XCTAssertEqual(ben.unreadNotes, 0)

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

        // New and for him alone: put in front of him, and red on both. Seen keeps it open, and turns it yellow.
        XCTAssertEqual(ben.newOrder?.id, order.id)
        XCTAssertEqual(ben.tone(of: order), .personal)
        XCTAssertEqual(ana.tone(of: order), .personal)
        ben.answer(order, .seen)
        try await wait("the leader sees Seen") { ana.answers[order.id]?[benID] == .seen }
        XCTAssertNil(ben.newOrder)
        XCTAssertEqual(ben.tone(of: order), .seen)
        XCTAssertEqual(ana.tone(of: order), .seen)
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
        XCTAssertEqual(ben.newOrder?.text, "Back by five")
        XCTAssertEqual(ben.tone(of: try XCTUnwrap(ben.newOrder)), .team)
        XCTAssertEqual(ben.orders.first?.text, "Back by five")
        XCTAssertEqual(ana.orders.first?.text, "Back by five")
        // A new move for the same people replaces the old one; an order can also be taken back.
        let elm = GeoPoint(latitude: 42.362, longitude: -71.062)
        XCTAssertTrue(ana.sendOrder(.moveTo, text: "The pond", at: oak, to: [benID]))
        try await wait("Ben has the pond") { ben.queue.contains { $0.text == "The pond" } }
        XCTAssertTrue(ana.sendOrder(.moveTo, text: "The elm", at: elm, to: [benID]))
        try await wait("the pond is replaced") { ben.queue.map(\.text) == ["Back by five", "The elm"] }
        XCTAssertEqual(ana.openOrders.compactMap(\.at), [elm], "one flag, at the new place")
        ana.cancelOrder(try XCTUnwrap(ana.orders.first { $0.text == "The elm" }))
        try await wait("the elm is taken back") { ben.queue.map(\.text) == ["Back by five"] }
        XCTAssertEqual(ben.cancelledOrders.count, 2)
        ben.answer(try XCTUnwrap(ben.orders.first { $0.text == "The elm" }), .done)
        XCTAssertNil(ben.myAnswers.first { $0.value == .done && $0.key != order.id })

        // Two more wait in the order they came: the oldest is the one to do next.
        XCTAssertTrue(ana.sendOrder(.holdPosition, text: "By the gate"))
        try await wait("Ben has the gate") { ben.queue.count == 2 }
        XCTAssertEqual(ben.queue.map(\.text), ["Back by five", "By the gate"])
        ben.answer(try XCTUnwrap(ben.queue.first), .done)
        XCTAssertEqual(ben.queue.map(\.text), ["By the gate"])
        let gate = try XCTUnwrap(ben.queue.first)
        ben.answer(gate, .cannot)
        XCTAssertEqual(ben.tone(of: gate), .cannot)
        XCTAssertTrue(ben.queue.isEmpty)
        XCTAssertEqual(ben.orders.count, 5, "answered and cancelled orders stay in the list")
        try await wait("the leader sees Can't") { ana.openOrders.isEmpty }
        ana.endSquad()
    }

    func testAPhoneStreamsToTheLeaderAndEitherCanStopIt() async throws {
        let ana = model("Ana"), ben = model("Ben"), cy = model("Cy")
        ana.startSquad(name: "Red", as: "Ana")
        try await wait("the leader's link") { ana.hostPort != nil }
        for (phone, name) in [(ben, "Ben"), (cy, "Cy")] {
            point(to: ana, phone)
            phone.videoSource = { PatternSource() }
            ana.openJoining()
            let shown = try XCTUnwrap(ana.invite).url(scheme: "squadz").absoluteString
            try await wait("listener with invite key") { ana.hostIsListening }
            phone.offer(shown)
            phone.join(try XCTUnwrap(phone.offered), as: name)
            try await wait("\(name) in") { phone.role == .member && phone.linkProblem == nil }
        }
        try await wait("everyone on the roster") { ana.squad?.members.count == 3 && cy.squad?.members.count == 3 }
        let benID = try XCTUnwrap(ben.me)

        // The leader can't stream to itself, and nothing streams until a phone starts.
        ana.startStreaming()
        XCTAssertFalse(ana.isStreaming)
        XCTAssertTrue(ana.streams.isEmpty)

        // Ben starts. The leader's device shows pictures; Cy can see that Ben is streaming, and gets none.
        ben.startStreaming()
        XCTAssertTrue(ben.isStreaming)
        try await wait("the leader lists Ben's stream") { ana.streams.map(\.member) == [benID] }
        try await wait("pictures on the leader's device") { ana.display.shown >= 5 }
        try await wait("Cy sees who is streaming") { cy.streams.map(\.member) == [benID] }
        XCTAssertEqual(cy.display.shown, 0)
        XCTAssertEqual(ben.display.shown, 0)

        // One at a time: Cy is turned down and told why.
        cy.startStreaming()
        try await wait("Cy is turned down") { !cy.isStreaming && cy.alert != nil }
        XCTAssertEqual(cy.alert, "Ben is streaming. One at a time.")
        XCTAssertEqual(ana.streams.map(\.member), [benID])

        // The leader stops it: Ben's phone stops sending.
        ana.stopStream(try XCTUnwrap(ana.streams.first?.id))
        try await wait("Ben's phone stops") { !ben.isStreaming }
        try await wait("nobody is listed") { ana.streams.isEmpty && cy.streams.isEmpty }
        let shown = ana.display.shown
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(ana.display.shown, shown, "no more pictures after the stop")

        // Ben starts again. Nothing is kept until the leader says, and then everyone can see that it is.
        ben.startStreaming()
        try await wait("streaming again") { ana.streams.count == 1 && ana.display.shown > shown + 3 }
        let mission = try XCTUnwrap(ana.missionID)
        XCTAssertNil(ben.missionID, "a member's phone keeps no log")
        XCTAssertFalse(ana.logs.entries(of: mission).contains { $0.isMedia })
        XCTAssertEqual(ben.streamingNote, "You are streaming to the leader")

        ana.startRecording()
        XCTAssertTrue(ana.isRecording)
        try await wait("Ben and Cy see the recording") { ben.streams.first?.recording == true && cy.streams.first?.recording == true }
        XCTAssertEqual(ben.streamingNote, "You are streaming to the leader, and being recorded")
        XCTAssertTrue(ana.snap())
        try await wait("Ben sees a still was kept") { ben.streams.first?.stills == 1 }
        XCTAssertEqual(ben.streamingNote, "You are streaming to the leader, and being recorded · 1 still kept")
        try await Task.sleep(for: .seconds(3))   // long enough to span a key frame

        // Ben stops: the clip is closed and filed in the mission's log, with the still.
        ben.stopStreaming()
        try await wait("stopped by Ben") { ana.streams.isEmpty }
        try await wait("the clip is in the log") { ana.logs.entries(of: mission).contains { $0.kind == .clip } }
        XCTAssertFalse(ana.isRecording)
        let log = ana.logs.entries(of: mission)
        let clip = try XCTUnwrap(log.first { $0.kind == .clip })
        let still = try XCTUnwrap(log.first { $0.kind == .still })
        XCTAssertEqual(clip.member, benID)
        XCTAssertEqual(clip.name, "Ben")
        XCTAssertGreaterThan(try XCTUnwrap(clip.seconds), 0.5)
        let clipFile = ana.logs.media(mission, try XCTUnwrap(clip.file))
        let stillFile = ana.logs.media(mission, try XCTUnwrap(still.file))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: clipFile.path)[.size] as? Int) ?? 0, 1000)
        let played = try await AVURLAsset(url: clipFile).load(.duration).seconds
        XCTAssertGreaterThan(played, 0.5, "the clip plays")
        let picture = try XCTUnwrap(UIImage(contentsOfFile: stillFile.path))
        XCTAssertEqual(picture.size.width, 320)

        // The log has the rest of what happened, in order, and reads on its own.
        XCTAssertEqual(log.first?.kind, .squadStarted)
        XCTAssertEqual(log.filter { $0.kind == .joined }.compactMap(\.name).sorted(), ["Ben", "Cy"])
        XCTAssertEqual(log.filter { $0.kind == .streamStarted }.count, 2)
        XCTAssertEqual(log.filter { $0.kind == .streamStopped }.count, 2)
        XCTAssertTrue(MissionLogView.summary(log).hasSuffix("1 clip · 1 still"), MissionLogView.summary(log))

        // Orders, answers, notes and positions go in too.
        XCTAssertTrue(ana.sendOrder(.holdPosition, text: "By the gate", to: [benID]))
        try await wait("Ben has the order") { ben.orders.count == 1 }
        ben.answer(try XCTUnwrap(ben.orders.first), .done)
        XCTAssertTrue(ben.sendNote("At the gate"))
        ben.setMyPosition(MemberPosition(at: GeoPoint(latitude: 42.37, longitude: -71.05), accuracy: 5, heading: 90, time: Date()), member: benID)
        try await wait("all of it is logged") {
            let kinds = Set(ana.logs.entries(of: mission).map(\.kind))
            return kinds.isSuperset(of: [.order, .orderAnswer, .note, .position])
        }
        let later = ana.logs.entries(of: mission)
        XCTAssertEqual(later.first { $0.kind == .order }?.text, "Hold position: By the gate, to Ben")
        XCTAssertEqual(later.first { $0.kind == .orderAnswer }?.text, "Done")
        XCTAssertEqual(later.first { $0.kind == .note }?.text, "At the gate")
        XCTAssertTrue(later.contains { $0.kind == .position && $0.member == benID && $0.heading == 90 && $0.name == "Ben" })

        // The log outlives the squad, can be exported whole, and can be deleted.
        ana.endSquad()
        XCTAssertEqual(ana.logs.entries(of: mission).last?.kind, .squadEnded)
        XCTAssertNotNil(ana.logs.missions().first { $0.id == mission }?.ended)
        let zip = try XCTUnwrap(ana.logs.export(mission))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0, 1000)
        ana.logs.delete(mission)
        XCTAssertTrue(ana.logs.missions().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipFile.path))
    }

    /// What an encoder gave, collected from its own queue.
    final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(isKey: Bool, data: Data)] = []
        func add(_ isKey: Bool, _ data: Data) { lock.lock(); items.append((isKey, data)); lock.unlock() }
        var all: [(isKey: Bool, data: Data)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testPicturesSurviveTheEncoderAndTheWire() async throws {
        // Made-up pictures, through H.264, into the frames a phone sends, and back to something a screen can show.
        let source = PatternSource()
        let got = Frames()
        let encoder = try XCTUnwrap(H264Encoder(width: source.width, height: source.height, kbps: 300) { got.add($0, $1) })
        for _ in 0..<12 { encoder.encode(try XCTUnwrap(source.picture())) }
        try await wait("the encoder's output") { got.all.count >= 12 }
        encoder.stop()

        let frames = got.all
        XCTAssertTrue(frames[0].isKey, "the first picture can be shown on its own")
        XCTAssertEqual(frames[0].data.prefix(4), H264Encoder.startCode)
        XCTAssertEqual(H264Display.units(frames[0].data).map { $0[0] & 0x1F }.prefix(2), [7, 8], "a key frame leads with its parameter sets")
        XCTAssertFalse(frames[1].isKey)
        let bytes = frames.reduce(0) { $0 + $1.data.count }
        XCTAssertLessThan(bytes, 150_000, "twelve small pictures at this bit rate are tens of kilobytes, not hundreds")

        let stream = UUID()
        let display = H264Display()
        var shown = 0
        for (n, frame) in frames.enumerated() {
            let sent = VideoMission.Frame(stream: stream, count: UInt32(n), isKey: frame.isKey, data: frame.data)
            let arrived = try XCTUnwrap(VideoMission.Frame(payload: sent.payload))
            shown += display.samples(arrived.data).count
        }
        XCTAssertEqual(shown, 12)

        // A viewer who missed the key frame shows nothing until the next one.
        let late = H264Display()
        XCTAssertTrue(late.samples(frames[1].data).isEmpty)
        XCTAssertEqual(late.samples(frames[0].data).count, 1)
        XCTAssertEqual(late.samples(frames[1].data).count, 1)
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
