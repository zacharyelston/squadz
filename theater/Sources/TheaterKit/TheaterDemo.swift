import CoreGeo
import Foundation
import Network
import SquadKit
import SquadLink

/// Explicit --demo fixture. It uses ephemeral keys and real observer links on loopback.
@MainActor
public final class TheaterDemo {
    private var rooms: [Room] = []
    public init(controller: TheaterController) throws {
        let first = try Room(name: "Ridge Team · demo", latitude: 44.0582, longitude: -121.3153)
        let second = try Room(name: "Creek Team · demo", latitude: 44.061, longitude: -121.31)
        rooms = [first, second]
        controller.fixedEndpoint = { [weak self] id in self?.rooms.first { $0.core.squadID == id }?.endpoint }
        for room in rooms {
            controller.allowDemoSquad(room.core.squadID)
            room.onReady = { [weak room, weak controller] in
                guard let room else { return }; try? controller?.join(room.invite.url(scheme: "squadz").absoluteString, name: "Theater demo")
            }
            room.start()
        }
    }
    public func stop() { rooms.forEach { $0.stop() } }

    @MainActor
    final class Room {
        var core: SquadCore<VideoMission>
        let invite: SquadInvite
        let host: SquadLinkHost
        let center: GeoPoint
        let leader: Member
        let member: Member
        var onReady: (() -> Void)?
        var timer: DispatchSourceTimer?
        private var fired = false
        private var step = 0
        var endpoint: NWEndpoint? { host.port.flatMap(NWEndpoint.Port.init(rawValue:)).map { .hostPort(host: "127.0.0.1", port: $0) } }
        init(name: String, latitude: Double, longitude: Double) throws {
            let origin = GeoPoint(latitude: latitude, longitude: longitude)
            center = origin
            leader = Member(name: "Mara", device: UUID()); member = Member(name: "Ben", device: UUID())
            var core = SquadCore(squad: Squad(name: name, members: [leader, member]), mission: VideoMission(), sharesPositions: true, sharesNotes: true)
            invite = core.openJoining(now: .now)
            _ = core.setZones([
                SquadZone(name: "Rally point", shape: .circle(center: center, radius: 80), rule: .goal),
                SquadZone(name: "Search area", shape: .polygon(vertices: [(-250.0,-200.0),(300.0,-200.0),(320.0,220.0),(-180.0,250.0)].map { Geo.offset(origin, east: $0.0, north: $0.1) }), rule: .allowedArea)
            ], now: .now)
            _ = core.sendOrder(.moveTo, text: "Meet at the rally point", at: center, now: .now)
            _ = core.postNote(FieldNote(author: "Mara", time: .now, text: "Sample squad. Ben's marker moves every two seconds."))
            self.core = core
            host = try SquadLinkHost(name: name, keys: core.linkKeys(now: .now), advertise: false)
            host.onOpened = { [weak self] peer, identity in MainActor.assumeIsolated { self?.core.linkOpened(peer, identity: identity) } }
            host.onMessage = { [weak self] message, peer in MainActor.assumeIsolated {
                guard let self else { return }; self.send(self.core.handle(message, from: peer, now: .now))
            } }
            host.onPeerClosed = { [weak self] peer in MainActor.assumeIsolated {
                guard let self else { return }; self.send(self.core.peerClosed(peer))
            } }
            host.onReady = { [weak self] _ in MainActor.assumeIsolated {
                guard let self, !self.fired else { return }; self.fired = true; self.onReady?()
            } }
        }
        func start() {
            host.start()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: 2)
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated {
                guard let self else { return }; self.step += 1
                self.send(self.core.setPosition(MemberPosition(at: self.center, accuracy: 5, heading: 45, time: .now), of: self.leader.id))
                let east = 165 * cos(Double(self.step) / 5), north = 115 * sin(Double(self.step) / 5)
                self.send(self.core.setPosition(MemberPosition(at: Geo.offset(self.center, east: east, north: north), accuracy: 6, heading: Double(self.step * 12 % 360), time: .now), of: self.member.id))
            } }
            timer.resume(); self.timer = timer
        }
        func send(_ out: [Outgoing]) { host.send(out); host.setKeys(core.linkKeys(now: .now)) }
        func stop() { timer?.cancel(); host.stop() }
    }
}
