import CoreGeo
import Foundation
import SquadKit
import ZoneKit

public struct WebMember: Encodable {
    public var id: MemberID
    public var name: String
    public var connected: Bool?
    public var position: MemberPosition?
}
public struct WebAnswer: Encodable {
    public var member: MemberID
    public var name: String
    public var response: OrderAck.Response
}
public struct WebOrder: Encodable {
    public var order: Order
    public var cancelled: Bool
    public var answers: [WebAnswer]
}
public struct WebNote: Encodable {
    public var id: UUID
    public var author: String
    public var text: String
    public var time: Date
    public var at: GeoPoint?
}
public struct WebZone: Encodable {
    public var id: UUID
    public var name: String
    public var rule: SquadZone.Rule
    public var members: [MemberID]?
    public var shape: String
    public var center: GeoPoint?
    public var radius: Double?
    public var vertices: [GeoPoint]?
    init(_ zone: SquadZone) {
        id = zone.id; name = zone.name; rule = zone.rule; members = zone.members
        switch zone.shape {
        case let .circle(point, size): shape = "circle"; center = point; radius = size
        case let .polygon(points): shape = "polygon"; vertices = points
        }
    }
}
public struct SquadViewState: Encodable {
    public var id: SquadID
    public var name: String
    public var connection: String
    public var problem: String?
    public var updated: Date?
    public var members: [WebMember]
    public var orders: [WebOrder]
    public var notes: [WebNote]
    public var zones: [WebZone]
    public var crossings: [ZoneEvent]
    public var observers: [SquadObserver]
    public var streams: [VideoMission.Stream]
    public var videoShared = false
}

/// A browser-safe projection: no invite, credential, link keys, inline media or opaque missions.
public struct ObservedSquad {
    public private(set) var squad: Squad
    public var connection = "connecting"
    public var problem: String?
    public private(set) var updated: Date?
    private var positions: [MemberID: MemberPosition] = [:]
    private var orders: [UUID: Order] = [:]
    private var cancelled: Set<UUID> = []
    private var notes: [UUID: FieldNote] = [:]
    private var status: SquadStatus?

    public init(squad: Squad) { self.squad = squad }
    public mutating func receive(_ body: SquadMessage.Body, now: Date = .now) {
        updated = now
        switch body {
        case let .observing(value):
            squad = value; orders = [:]; cancelled = []; notes = [:]; positions = [:]; status = nil
        case let .status(value):
            guard value.squad.id == squad.id else { return }
            squad = value.squad; status = value
            let roster = Set(squad.members.map(\.id))
            positions = positions.filter { roster.contains($0.key) }
        case let .positions(report):
            guard report.squad == squad.id else { return }
            let roster = Set(squad.members.map(\.id))
            for position in report.positions {
                guard let member = position.member, roster.contains(member),
                      position.at.latitude.isFinite, abs(position.at.latitude) <= 90,
                      position.at.longitude.isFinite, abs(position.at.longitude) <= 180,
                      position.accuracy.isFinite, position.accuracy >= 0 else { continue }
                if let old = positions[member], old.time > position.time { continue }
                positions[member] = position
            }
        case let .order(order):
            orders[order.id] = order
            if orders.count > 100, let oldest = orders.values.min(by: { $0.time < $1.time }) { orders[oldest.id] = nil; cancelled.remove(oldest.id) }
        case let .orderCancel(id): if orders[id] != nil { cancelled.insert(id) }
        case let .note(note):
            var safe = note; safe.photo = nil
            notes[note.id] = safe
            if notes.count > 100, let oldest = notes.values.min(by: { $0.time < $1.time }) { notes[oldest.id] = nil }
        case let .notice(notice): if let member = notice.member { positions[member] = nil }
        default: break
        }
    }
    public var view: SquadViewState {
        let connections = Dictionary((status?.observerState?.connections ?? []).map { ($0.member, $0.connected) }, uniquingKeysWith: { _, last in last })
        let names = Dictionary(squad.members.map { ($0.id, $0.name) }, uniquingKeysWith: { _, last in last })
        return SquadViewState(id: squad.id, name: squad.name, connection: connection, problem: problem, updated: updated,
            members: squad.members.map { WebMember(id: $0.id, name: $0.name, connected: connections[$0.id], position: positions[$0.id]) },
            orders: orders.values.sorted { $0.time > $1.time }.map { order in
                WebOrder(order: order, cancelled: cancelled.contains(order.id), answers: (status?.observerState?.answers ?? []).filter { $0.order == order.id }.map {
                    WebAnswer(member: $0.member, name: names[$0.member] ?? "Former member", response: $0.response)
                })
            },
            notes: notes.values.sorted { $0.time < $1.time }.map { WebNote(id: $0.id, author: $0.author, text: $0.text, time: $0.time, at: $0.at) },
            zones: (status?.zones ?? []).map(WebZone.init), crossings: status?.zoneEvents ?? [], observers: status?.observers ?? [],
            streams: status.flatMap(VideoMission.status(in:))?.streams ?? [])
    }
}
