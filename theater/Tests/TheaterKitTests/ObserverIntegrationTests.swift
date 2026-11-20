import CoreGeo
import Foundation
import Network
import SquadKit
import SquadLink
import XCTest
@testable import TheaterKit

@MainActor
final class ObserverIntegrationTests: XCTestCase {
    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let end = Date.now.addingTimeInterval(12)
        while !condition() {
            if Date.now > end { throw TheaterError.message("Timed out: " + message) }
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    private func setup() async throws -> (TheaterController, TheaterDemo.Room) {
        var options = TheaterOptions(); options.port = 0
        let controller = try TheaterController(options: options, persist: false)
        let room = try TheaterDemo.Room(name: "Integration squad", latitude: 42.36, longitude: -71.06)
        controller.fixedEndpoint = { _ in room.endpoint }
        room.start()
        try await wait("leader listener") { room.host.isListening }
        try controller.join(room.invite.url(scheme: "squadz").absoluteString, name: "Desk observer")
        try await wait("observer linked") { controller.snapshot.squads.first?.connection == "connected" && controller.snapshot.squads.first?.members.contains(where: { $0.position != nil }) == true }
        return (controller, room)
    }
    func testObserverFollowsPositionsOrdersNotesAnswersAndRevocation() async throws {
        let (controller, room) = try await setup()
        defer { controller.stop(); room.stop() }
        let initial = try XCTUnwrap(controller.snapshot.squads.first)
        XCTAssertEqual(initial.members.count, 2)
        XCTAssertFalse(initial.orders.isEmpty); XCTAssertFalse(initial.notes.isEmpty)
        XCTAssertEqual(room.core.observerRoster.first?.name, "Desk observer")
        XCTAssertEqual(room.core.observerRoster.first?.connected, true)
        var credential: MemberCredential?
        let joiner = SquadEnroller(invite: room.invite, name: "Phone", device: UUID())
        joiner.fixedEndpoint = room.endpoint
        joiner.onDone = { result in MainActor.assumeIsolated { if case let .success(value) = result { credential = value } } }
        joiner.start()
        defer { joiner.cancel() }
        try await wait("phone credential") { credential != nil }
        let phone = try XCTUnwrap(credential), member = try XCTUnwrap(phone.member)
        let client = SquadLinkClient(credential: phone, name: "Phone", device: UUID())
        client.fixedEndpoint = room.endpoint; client.start(); defer { client.stop() }
        try await wait("phone linked") { room.core.peers.values.contains(member) }
        room.send(room.core.sendOrder(.holdPosition, text: "Wait here", to: [member], now: .now))
        let order = try XCTUnwrap(room.core.orders.last)
        client.send(.orderAck(OrderAck(order: order.id, response: .done)))
        client.send(.note(FieldNote(author: "Phone", time: .now, text: "Arrived at observation point")))
        let target = GeoPoint(latitude: 42.3604, longitude: -71.0602)
        client.send(.position(MemberPosition(at: target, accuracy: 4, heading: 123, time: .now)))
        try await wait("answer, note and position in Theater") {
            let view = controller.snapshot.squads.first
            return view?.orders.first(where: { $0.order.id == order.id })?.answers.first?.response == .done
                && view?.notes.contains(where: { $0.text == "Arrived at observation point" }) == true
                && view?.members.first(where: { $0.id == member })?.position?.at == target
        }
        let json = String(data: try controller.json(), encoding: .utf8)!
        XCTAssertFalse(json.contains(phone.secret.base64EncodedString()))
        XCTAssertFalse(json.contains("\"secret\"")); XCTAssertFalse(json.contains("\"enrol\""))
        let observer = try XCTUnwrap(room.core.credentials.first(where: { $0.role == .observer }))
        room.send(room.core.revoke(credential: observer.id, now: .now))
        try await wait("Theater removed") { controller.snapshot.squads.first?.connection == "removed" }
        XCTAssertTrue(room.core.observerRoster.isEmpty)
    }
    func testMultipleSquadsAndIndependentViewState() async throws {
        var options = TheaterOptions(); options.port = 0
        let controller = try TheaterController(options: options, persist: false)
        let demo = try TheaterDemo(controller: controller)
        defer { controller.stop(); demo.stop() }
        try await wait("two connected squads") { controller.snapshot.squads.count == 2 && controller.snapshot.squads.allSatisfy { $0.connection == "connected" && !$0.zones.isEmpty } }
        let ids = controller.snapshot.squads.map(\.id)
        XCTAssertNotEqual(ids[0], ids[1])
        try controller.forget(ids[0])
        XCTAssertEqual(controller.snapshot.squads.count, 1)
        XCTAssertEqual(controller.snapshot.squads.first?.id, ids[1])
    }
    func testLocalStopDoesNotRevokeOrRemoveTheSavedSquad() async throws {
        let (controller, room) = try await setup()
        defer { room.stop() }
        controller.stop()
        XCTAssertEqual(controller.snapshot.squads.count, 1)
        XCTAssertNotEqual(controller.snapshot.squads.first?.connection, "removed")
        XCTAssertEqual(room.core.observerRoster.count, 1)
    }
    func testOfflineTilesStayInsideConfiguredDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tiles = root.appendingPathComponent("tiles")
        try FileManager.default.createDirectory(at: tiles.appendingPathComponent("0/0"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tiles.appendingPathComponent("1/0"), withIntermediateDirectories: true)
        let content = Data([137, 80, 78, 71])
        try content.write(to: tiles.appendingPathComponent("0/0/0.png"))
        let outside = root.appendingPathComponent("outside.png")
        try content.write(to: outside)
        try FileManager.default.createSymbolicLink(at: tiles.appendingPathComponent("1/0/0.png"), withDestinationURL: outside)
        var options = TheaterOptions(); options.port = 0; options.tilesDirectory = tiles
        let controller = try TheaterController(options: options, persist: false)
        let server = TheaterHTTPServer(controller: controller)
        defer { server.stop(); controller.stop() }
        try server.start(); try await wait("tile listener") { server.port != 0 }
        for (path, status) in [("/tiles/0/0/0.png", 200), ("/tiles/0/1/0.png", 404), ("/tiles/1/0/0.png", 404), ("/tiles/23/0/0.png", 404)] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)" + path)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, status, path)
            if status == 200 { XCTAssertEqual(data, content) }
        }
    }
    func testHTTPPagesSnapshotSSEAndNoMutationRoutes() async throws {
        let (controller, room) = try await setup()
        let server = TheaterHTTPServer(controller: controller)
        defer { server.stop(); controller.stop(); room.stop() }
        try server.start(); try await wait("HTTP listener") { server.port != 0 }
        let base = "http://127.0.0.1:\(server.port)"
        for path in ["/", "/squads/\(room.core.squadID.raw)/map", "/squads/\(room.core.squadID.raw)/dashboard", "/squads/\(room.core.squadID.raw)/wall", "/theater.js", "/theater.css", "/api/state"] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, path); XCTAssertFalse(data.isEmpty)
        }
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: URL(string: base + "/events")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var messages = 0
        for try await line in bytes.lines where line.hasPrefix("data: ") {
            messages += 1
            if messages == 1 {
                let point = GeoPoint(latitude: 42.3607, longitude: -71.0607)
                room.send(room.core.setPosition(MemberPosition(at: point, accuracy: 4, time: .now), of: room.leader.id))
            } else {
                XCTAssertTrue(line.contains("42.3607")); break
            }
        }
        XCTAssertEqual(messages, 2)
        for endpoint in ["/api/orders", "/api/notes", "/api/zones", "/api/start-video"] {
            var request = URLRequest(url: URL(string: base + endpoint)!); request.httpMethod = "POST"
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        }
        var forged = URLRequest(url: URL(string: base + "/api/join")!)
        forged.httpMethod = "POST"; forged.setValue("http://evil.example", forHTTPHeaderField: "Origin")
        forged.setValue("application/json", forHTTPHeaderField: "Content-Type"); forged.setValue("1", forHTTPHeaderField: "X-Theater-Request"); forged.httpBody = Data("{}".utf8)
        let (_, refusal) = try await URLSession.shared.data(for: forged)
        XCTAssertEqual((refusal as? HTTPURLResponse)?.statusCode, 403)
    }
}
