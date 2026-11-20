import Foundation
import CryptoKit
import CoreGeo

// What the core's messages carry. Nothing here knows what a squad is out doing: that's a
// mission's business (see Mission.swift).

public struct Hello: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        /// A squad member's phone.
        case member
        /// A watcher: it receives status and positions and can send nothing the squad acts on.
        case observer
        /// A phone sending notes and files to a host that isn't a squad. A squad refuses it.
        case contributor
    }
    public var name: String
    public var device: UUID
    /// A request. On a credential link the credential's role is what counts. Nil means member.
    public var role: Role?
    /// 16 random bytes, fresh for every hello. The leader's signed answer covers it.
    public var nonce: Data
    /// On an invite link only: this device's one-time P-256 key (X9.63), which the leader seals
    /// the credential to.
    public var key: Data?
    public init(name: String, device: UUID, role: Role? = nil, nonce: Data = .random(16), key: Data? = nil) {
        self.name = name
        self.device = device
        self.role = role
        self.nonce = nonce
        self.key = key
    }
}

public struct Welcome: Codable, Equatable, Sendable {
    public var member: MemberID
    public var squad: Squad
    public init(member: MemberID, squad: Squad) {
        self.member = member
        self.squad = squad
    }
}

public struct MemberPosition: Codable, Equatable, Sendable {
    /// Set by the leader from the connection; whatever a phone puts here is overwritten.
    public var member: MemberID?
    public var at: GeoPoint
    /// GPS horizontal accuracy, metres.
    public var accuracy: Double
    public var heading: Double?
    public var time: Date

    public init(member: MemberID? = nil, at: GeoPoint, accuracy: Double, heading: Double? = nil, time: Date) {
        self.member = member
        self.at = at
        self.accuracy = accuracy
        self.heading = heading
        self.time = time
    }
}

/// Leader → observers: members' positions.
public struct PositionsReport: Codable, Equatable, Sendable {
    public var squad: SquadID
    public var positions: [MemberPosition]
    public init(squad: SquadID, positions: [MemberPosition]) {
        self.squad = squad
        self.positions = positions
    }
}

/// Anyone can call check fire, at any time. Only the leader lifts it.
public struct CheckFire: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var by: String
    public init(id: UUID = UUID(), by: String) {
        self.id = id
        self.by = by
    }
}

/// Leader → everyone: something that happened to the squad and is worth telling people, like a
/// member leaving. Nothing acts on a notice; it is for people to read.
public struct Notice: Codable, Equatable, Sendable, Identifiable {
    /// A device that doesn't know a kind shows the notice's text.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// The member left of their own accord.
        public static let left = Kind(rawValue: "left")
        /// The leader took the member off the squad.
        public static let removed = Kind(rawValue: "removed")
    }

    public var id: UUID
    public var kind: Kind
    /// For people, like "Ana left the squad."
    public var text: String
    /// Who it is about, if anyone. They may no longer be on the roster.
    public var member: MemberID?
    public var time: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, member: MemberID? = nil, time: Date) {
        self.id = id
        self.kind = kind
        self.text = text
        self.member = member
        self.time = time
    }
}

/// The leader's order to one member, several, or the whole squad.
public struct Order: Codable, Equatable, Sendable, Identifiable {
    /// The core's kinds are below. A mission adds its own by extending this type and listing
    /// them in `Mission.orderKinds`; a device that doesn't know a kind shows the order's text.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Go to `at`.
        public static let moveTo = Kind(rawValue: "moveTo")
        public static let holdPosition = Kind(rawValue: "holdPosition")
        /// Take photos (at `at`, if given).
        public static let capture = Kind(rawValue: "capture")
        /// Free text only.
        public static let note = Kind(rawValue: "note")

        public static let core: [Kind] = [.moveTo, .holdPosition, .capture, .note]

        /// A title for the core's kinds; nil for a mission's.
        public var coreTitle: String? {
            switch self {
            case .moveTo: return "Move to"
            case .holdPosition: return "Hold position"
            case .capture: return "Capture"
            case .note: return "Note"
            default: return nil
            }
        }
    }

    public static let maxText = 140

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// A place, for move-to and capture orders.
    public var at: GeoPoint?
    /// The members it's for; nil means the whole squad.
    public var to: [MemberID]?
    public var time: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, at: GeoPoint? = nil, to: [MemberID]? = nil, time: Date) {
        self.id = id
        self.kind = kind
        self.text = String(text.prefix(Self.maxText))
        self.at = at
        self.to = to
        self.time = time
    }

    public func isFor(_ member: MemberID) -> Bool { to?.contains(member) ?? true }
}

/// A member's answer to an order.
public struct OrderAck: Codable, Equatable, Sendable {
    public enum Response: String, Codable, Sendable, CaseIterable {
        case seen, done, cannot
    }
    public var order: UUID
    public var response: Response
    public init(order: UUID, response: Response) {
        self.order = order
        self.response = response
    }
}

/// A note pinned to a place: something seen, a hazard.
public struct FieldNote: Codable, Equatable, Sendable, Identifiable {
    public static let maxText = 500
    /// A note's photo travels inline only when small; larger files go as `FileOffer`s.
    public static let maxInlinePhotoBytes = 300_000

    public var id: UUID
    /// Set by the leader from the connection; whatever a phone puts here is overwritten.
    public var author: String
    public var time: Date
    /// What the note belongs to (a mission's own ID for a place, say), if known.
    public var field: String?
    public var at: GeoPoint?
    public var accuracy: Double?
    public var text: String
    /// A small JPEG, inline.
    public var photo: Data?

    public init(id: UUID = UUID(), author: String, time: Date, field: String? = nil, at: GeoPoint? = nil,
                accuracy: Double? = nil, text: String, photo: Data? = nil) {
        self.id = id
        self.author = author
        self.time = time
        self.field = field
        self.at = at
        self.accuracy = accuracy
        self.text = String(text.prefix(Self.maxText))
        self.photo = photo.flatMap { $0.count <= Self.maxInlinePhotoBytes ? $0 : nil }
    }
}

/// A file about to be sent in chunks.
public struct FileOffer: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// One file of a capture (a JPEG, or its data).
        case capture
        /// A full-size photo for a field note.
        case notePhoto
    }
    public static let maxBytes = 50_000_000
    public static let chunkBytes = 256 * 1024

    public var id: UUID
    public var kind: Kind
    /// The capture or note it belongs to: files with the same group land in one folder.
    public var group: UUID
    /// A plain file name, no folders.
    public var name: String
    public var size: Int
    /// SHA-256 of the whole file, hex.
    public var sha256: String
    public var field: String?

    public init(id: UUID = UUID(), kind: Kind, group: UUID, name: String, size: Int, sha256: String, field: String?) {
        self.id = id
        self.kind = kind
        self.group = group
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.field = field
    }

    /// Only a plain file name: no folders, no hidden files, nothing that could escape the folder.
    public var safeName: String? {
        let n = (name as NSString).lastPathComponent
        guard !n.isEmpty, n == name, !n.hasPrefix("."), !n.contains("/"), !n.contains("\\"), n.count <= 120 else { return nil }
        return n
    }

    public var chunkCount: Int { max(1, (size + Self.chunkBytes - 1) / Self.chunkBytes) }
}

public struct FileChunk: Codable, Equatable, Sendable {
    public var file: UUID
    public var index: Int
    public var data: Data
    public init(file: UUID, index: Int, data: Data) {
        self.file = file
        self.index = index
        self.data = data
    }
}

/// What the receiver did with a note or a file.
public struct Receipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case received, stored, refused
    }
    public var id: UUID
    public var status: Status
    public var detail: String

    public init(id: UUID, status: Status, detail: String = "") {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

public extension Data {
    /// SHA-256, hex.
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

/// Why the squad is held. The core raises one (check fire); a mission raises its own, under its
/// own ID. Holds only ever add: see `SquadCore.holds`.
public struct Hold: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let coreSource = "core"

    /// Who raised it: `coreSource`, or a mission's ID.
    public var source: String
    /// Which of that source's holds it is.
    public var kind: String
    /// The member it's about, if it's about one.
    public var member: MemberID?
    /// For people.
    public var text: String

    public init(source: String, kind: String, member: MemberID? = nil, text: String) {
        self.source = source
        self.kind = kind
        self.member = member
        self.text = text
    }

    public static func checkFire(by: String) -> Hold {
        Hold(source: coreSource, kind: "checkFire", text: "Check fire, called by \(by).")
    }

    public var description: String { text }
}

/// One mission's part of the squad's status, in that mission's own format.
public struct MissionStatus: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var payload: Data
    public init(id: String, version: Int, payload: Data) {
        self.id = id
        self.version = version
        self.payload = payload
    }
}

/// The squad's state as its members see it: the roster, the holds, and one section per running
/// mission.
public struct SquadStatus: Codable, Equatable, Sendable {
    public var revision: Int
    public var squad: Squad
    public var holds: [Hold]
    public var missions: [MissionStatus]
    public init(revision: Int, squad: Squad, holds: [Hold], missions: [MissionStatus] = []) {
        self.revision = revision
        self.squad = squad
        self.holds = holds
        self.missions = missions
    }

    /// A mission's section, if this squad runs that mission at that version.
    public func mission(_ id: String, version: Int) -> Data? {
        missions.first { $0.id == id && $0.version == version }?.payload
    }
}

/// A mission's own message, opaque to the core.
public struct MissionMessage: Codable, Equatable, Sendable {
    public var id: String
    public var version: Int
    public var payload: Data
    public init(id: String, version: Int, payload: Data) {
        self.id = id
        self.version = version
        self.payload = payload
    }
}
