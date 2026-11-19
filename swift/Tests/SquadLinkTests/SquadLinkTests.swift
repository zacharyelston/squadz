import Foundation
import Network
import XCTest
import SquadKit
@testable import SquadLink

/// Real sockets on this Mac: a leader's host and a phone's connection over TLS keyed from the
/// join code.
final class SquadLinkTests: XCTestCase {
    let queue = DispatchQueue(label: "squad-link-test")

    /// A leader on a loopback port, wired to a SquadCore the way an app will wire it.
    private func startLeader(code: String, service: SquadService = .squadz) throws -> (SquadLinkHost, UInt16) {
        var squad = SquadCore(squad: Squad(name: "Red"), mission: NoMission(), joinCode: code)
        let host = try SquadLinkHost(name: "Red", joinCode: code, service: service, advertise: false, queue: queue)
        host.onMessage = { [unowned host] m, peer in host.send(squad.handle(m, from: peer, now: Date())) }
        let ready = expectation(description: "listening")
        host.onReady = { _ in ready.fulfill() }
        host.start()
        wait(for: [ready], timeout: 5)
        host.onReady = nil   // it reports ready again after a restart
        return (host, host.port!)
    }

    private func local(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    func testJoinOverTLS() throws {
        let code = JoinCode.make()
        let (host, port) = try startLeader(code: code)
        defer { host.stop() }

        let phone = SquadConnection(to: local(port), joinCode: code, queue: queue)
        let welcomed = expectation(description: "welcome")
        let status = expectation(description: "status")
        status.assertForOverFulfill = false
        phone.onMessage = { m in
            switch m.body {
            case let .welcome(w):
                XCTAssertEqual(w.squad.members.map(\.name), ["Ana"])
                welcomed.fulfill()
            case .status: status.fulfill()
            default: break
            }
        }
        phone.onState = { s in if s == .ready { phone.send(.hello(Hello(name: "Ana", device: UUID(), joinCode: code))) } }
        phone.start()
        wait(for: [welcomed, status], timeout: 5)
        phone.cancel()
    }

    func testWrongCodeCantConnect() throws {
        let (host, port) = try startLeader(code: "ABC234")
        defer { host.stop() }
        let phone = SquadConnection(to: local(port), joinCode: "XYZ789", queue: queue)
        let failed = expectation(description: "refused")
        failed.assertForOverFulfill = false
        phone.onState = { s in
            if case .failed = s { failed.fulfill() }
            if s == .ready { XCTFail("connected with the wrong code") }
        }
        phone.onMessage = { m in XCTFail("got \(m.body)") }
        phone.start()
        wait(for: [failed], timeout: 10)
        phone.cancel()
    }

    /// Two apps' squads don't share keys: the right code for the wrong app doesn't connect.
    func testAnotherAppsServiceCantConnect() throws {
        let (host, port) = try startLeader(code: "ABC234", service: SquadService(type: "_other._tcp", app: "Other"))
        defer { host.stop() }
        let phone = SquadConnection(to: local(port), joinCode: "ABC234", queue: queue)
        let failed = expectation(description: "refused")
        failed.assertForOverFulfill = false
        phone.onState = { s in
            if case .failed = s { failed.fulfill() }
            if s == .ready { XCTFail("connected to another app's squad") }
        }
        phone.start()
        wait(for: [failed], timeout: 10)
        phone.cancel()
    }

    /// The leader's device sleeping: its side of every link drops and its listener restarts. The
    /// phone's client finds it again and rejoins as the same member.
    func testClientRejoinsAfterTheHostDrops() throws {
        let code = JoinCode.make()
        let (host, port) = try startLeader(code: code)
        defer { host.stop() }

        let device = UUID()
        let client = SquadLinkClient(squadName: "Red", joinCode: code, hello: Hello(name: "Ana", device: device, joinCode: code), queue: queue)
        client.fixedEndpoint = local(port)
        client.baseDelay = 0.2
        var welcomes: [MemberID] = []
        let first = expectation(description: "first welcome")
        let second = expectation(description: "welcome after the drop")
        var statuses: [SquadLinkClient.Status] = []
        client.onStatus = { statuses.append($0) }
        client.onMessage = { m in
            guard case let .welcome(w) = m.body else { return }
            welcomes.append(w.member)
            if welcomes.count == 1 { first.fulfill() } else if welcomes.count == 2 { second.fulfill() }
        }
        client.start()
        wait(for: [first], timeout: 5)

        queue.sync {
            for c in host.connections.values { c.cancel() }
            host.restart()
        }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(welcomes.count, 2)
        XCTAssertEqual(welcomes[0], welcomes[1], "rejoined as the same member")
        XCTAssertTrue(statuses.contains { if case .reconnecting = $0 { return true }; return false }, "\(statuses)")
        XCTAssertEqual(host.port, port, "the restarted listener keeps its port")
        queue.sync { client.stop() }
    }

    func testClientStopsOnAWrongCode() throws {
        let (host, port) = try startLeader(code: "ABC234")
        defer { host.stop() }
        let client = SquadLinkClient(squadName: "Red", joinCode: "XYZ789",
                                     hello: Hello(name: "Eve", device: UUID(), joinCode: "XYZ789"), queue: queue)
        client.fixedEndpoint = local(port)
        let stopped = expectation(description: "gave up")
        client.onStatus = { s in if case .stopped = s { stopped.fulfill() } }
        client.start()
        wait(for: [stopped], timeout: 10)
    }

    /// Over a real network a wrong code can leave the handshake hanging instead of failing. A host
    /// that accepts TCP and never answers shows the same thing: the client must stop, not hang.
    func testAHandshakeThatNeverAnswersStopsTheClient() throws {
        let silent = try NWListener(using: .tcp)
        silent.newConnectionHandler = { c in c.start(queue: self.queue) }   // accept, say nothing
        let ready = expectation(description: "listening")
        silent.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        silent.start(queue: queue)
        wait(for: [ready], timeout: 5)
        defer { silent.cancel() }
        let client = SquadLinkClient(squadName: "Red", joinCode: "ABC234",
                                     hello: Hello(name: "Eve", device: UUID(), joinCode: "ABC234"), queue: queue)
        client.fixedEndpoint = local(silent.port!.rawValue)
        let stopped = expectation(description: "gave up")
        var why = ""
        client.onStatus = { s in if case let .stopped(w) = s { why = w; stopped.fulfill() } }
        client.start()
        wait(for: [stopped], timeout: 15)
        XCTAssertEqual(why, "Couldn't connect. Check the code.")
    }
}
