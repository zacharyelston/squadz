import CoreGeo
import ZoneKit
import Foundation

public struct SquadZone: Codable, Equatable, Identifiable, Sendable {
    public typealias Rule = ZoneRule
    public var id: UUID
    public var name: String
    public var shape: ZoneShape
    public var rule: Rule
    /// Nil monitors the whole squad, including the leader.
    public var members: [MemberID]?

    public init(id: UUID = UUID(), name: String, shape: ZoneShape, rule: Rule, members: [MemberID]? = nil) {
        self.id = id; self.name = name; self.shape = shape; self.rule = rule; self.members = members
    }
    public var definition: ZoneDefinition { ZoneDefinition(id: id, name: name, shape: shape, rule: rule) }
    public func includes(_ member: MemberID) -> Bool { members?.contains(member) ?? true }
    public var validationError: String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 40 else { return "Give the zone a label of 1 to 40 characters." }
        if let members, members.isEmpty { return "Pick at least one member, or the whole squad." }
        return shape.validationError
    }
}

public struct ZoneEvent: Codable, Equatable, Identifiable, Sendable {
    public typealias Kind = ZoneCrossing.Kind
    public var id: UUID
    public var zone: UUID
    public var zoneName: String
    public var member: MemberID
    public var memberName: String
    public var kind: Kind
    public var time: Date
    public var text: String { "\(memberName) \(kind == .arrived ? "reached" : "left") \(zoneName)." }
    public init(zone: SquadZone, member: Member, kind: Kind, time: Date) {
        id = UUID(); self.zone = zone.id; zoneName = zone.name; self.member = member.id
        memberName = member.name; self.kind = kind; self.time = time
    }
}
