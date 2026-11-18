import Foundation

/// The server's answers (docs/MOBILE_CLIENT.md §4).

struct MemberInfo: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct SquadInfo: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let leaderID: String
    let members: [MemberInfo]

    enum CodingKeys: String, CodingKey { case id, name, leaderID = "leader_id", members }
}

struct TileSource: Decodable, Equatable, Sendable {
    /// Relative to the server, e.g. "tiles/{z}/{x}/{y}.png".
    let path: String
    let attribution: String?
    let maxZoom: Int?

    enum CodingKeys: String, CodingKey { case path, attribution, maxZoom = "max_zoom" }
}

struct Me: Decodable, Equatable, Sendable {
    let deviceID: String
    let name: String
    let squad: SquadInfo?
    let pollSeconds: Int
    /// How long the server waits before it calls a position stale.
    let staleSeconds: Int?
    let tiles: TileSource?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id", name, squad, pollSeconds = "poll_seconds", staleSeconds = "stale_seconds", tiles
    }
}

/// What the server adds to a pairing answer.
struct PairInfo: Decodable, Sendable {
    let name: String
    let squad: SquadInfo?
}

struct Located: Decodable, Equatable, Identifiable, Sendable {
    let memberID: String
    let name: String
    let latitude: Double
    let longitude: Double
    let accuracy: Double?
    /// Seconds since the member last reported, by the server's clock.
    let age: Int
    let stale: Bool?

    var id: String { memberID }
    var isStale: Bool { stale ?? false }

    enum CodingKeys: String, CodingKey { case memberID = "member_id", name, latitude, longitude, accuracy, age, stale }
}

struct LocationsReply: Decodable, Sendable {
    let squad: SquadInfo
    let locations: [Located]
}

struct InviteReply: Decodable, Sendable {
    let payload: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey { case payload = "qr_payload", expiresIn = "expires_in" }
}

/// A position report. Fields the phone doesn't know are left out.
struct PositionReport: Encodable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var accuracy: Double?
    var heading: Double?
    var speed: Double?
}

struct NameBody: Encodable, Sendable { let name: String }
