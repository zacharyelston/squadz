import Foundation

// Who's who in a squad.

public enum SquadProtocol {
    /// The core's wire version (docs/WIRE.md). Bumped on any change to the core's messages; a
    /// device on another version is refused (fail closed). A mission's messages carry the
    /// mission's own version, so changing a mission doesn't change this.
    public static let version = 7
}

/// Six characters, without the ones people misread (0/O, 1/I/L).
public enum JoinCode {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &g)! })
    }
    public static func normalized(_ code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
}

/// An ID that travels as a bare UUID string.
public protocol WireID: Codable, Hashable, Sendable, CustomStringConvertible {
    var raw: UUID { get }
    init(_ raw: UUID)
}

public extension WireID {
    init(from decoder: Decoder) throws { self.init(try decoder.singleValueContainer().decode(UUID.self)) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    var description: String { String(raw.uuidString.prefix(8)) }
}

public struct SquadID: WireID {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

public struct MemberID: WireID {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

/// One end of a link, as the transport knows it. The leader identifies senders by this, never by
/// a field a message carries about itself. It never crosses the wire.
public struct PeerID: Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// What a member does in the squad. The core knows only `member`; a mission adds its own
/// (golf's gunner) by extending this type.
public struct MemberRole: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let member = MemberRole(rawValue: "member")
}

public struct Member: Codable, Equatable, Sendable, Identifiable {
    public var id: MemberID
    public var name: String
    /// The phone's own ID, so a member who drops out rejoins as the same member.
    public var device: UUID
    public var role: MemberRole

    public init(id: MemberID = MemberID(), name: String, device: UUID, role: MemberRole = .member) {
        self.id = id
        self.name = name
        self.device = device
        self.role = role
    }
}

public struct Squad: Codable, Equatable, Sendable {
    public var id: SquadID
    public var name: String
    public var members: [Member]

    public init(id: SquadID = SquadID(), name: String, members: [Member] = []) {
        self.id = id
        self.name = name
        self.members = members
    }
}
