import Foundation

/// What the leader's device shows as a QR code while joining is open: a link like
/// `squadz://join?v=1&squad=…&name=…&enrol=…&cmd=…&tag=…&exp=…`, with `relay` and `relay_pin` when
/// the squad can also be reached through a relay.
///
/// It carries no long-term key: `enrol` only opens an invite link, and stops working at `exp` or
/// when the leader closes joining. The app shows "Join *name* led by *by*?" and joins only on a
/// tap; scanning alone joins nothing.
public struct SquadInvite: Equatable, Sendable {
    public static let version = 1

    public var squad: SquadID
    /// For display only.
    public var name: String
    /// The invite's secret, 16 random bytes.
    public var enrol: Data
    /// SHA-256 fingerprint of the leader's identity key. The joining device refuses an answer
    /// signed by any other key.
    public var leader: Data
    public var expires: Date
    /// The leader's device name, for display only.
    public var by: String?
    /// Where the squad can be reached when its leader's device isn't on this network.
    public var relay: RelayAddress?

    public init(squad: SquadID, name: String, enrol: Data, leader: Data, expires: Date, by: String? = nil,
                relay: RelayAddress? = nil) {
        self.squad = squad
        self.name = name
        self.enrol = enrol
        self.leader = leader
        // The link carries whole seconds.
        self.expires = Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down))
        self.by = by
        self.relay = relay
    }

    public var tag: String { squad.tag }
    public var linkKey: LinkKey { .invite(secret: enrol, squad: squad) }
    public func isExpired(now: Date) -> Bool { now >= expires }

    public enum ParseError: Error, Equatable {
        /// Not a squad invite for this app.
        case notAnInvite
        /// A newer or older kind of invite than this app reads.
        case unsupportedVersion
        case malformed
    }

    public func url(scheme: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "join"
        var items = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "squad", value: squad.raw.uuidString),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "enrol", value: enrol.base64URL),
            URLQueryItem(name: "cmd", value: leader.base64URL),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "exp", value: String(Int(expires.timeIntervalSince1970))),
        ]
        if let by { items.append(URLQueryItem(name: "by", value: by)) }
        if let relay {
            items.append(URLQueryItem(name: "relay", value: relay.text))
            if let pin = relay.pin { items.append(URLQueryItem(name: "relay_pin", value: pin.base64URL)) }
        }
        c.queryItems = items
        // Every field above is a valid URL part.
        return c.url!
    }

    /// Reads a scanned link. Whether it has expired is a separate question (`isExpired`), so the
    /// app can say so.
    public init(url: URL, scheme: String) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == scheme.lowercased(), c.host == "join" else { throw ParseError.notAnInvite }
        var fields: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard fields[item.name] == nil else { throw ParseError.malformed }   // a field given twice
            fields[item.name] = item.value ?? ""
        }
        guard let v = fields["v"].flatMap(Int.init) else { throw ParseError.malformed }
        guard v == Self.version else { throw ParseError.unsupportedVersion }
        guard let id = fields["squad"].flatMap(UUID.init(uuidString:)),
              let name = fields["name"], !name.isEmpty, name.count <= 100,
              let enrol = fields["enrol"].flatMap(Data.init(base64URL:)), enrol.count == 16,
              let leader = fields["cmd"].flatMap(Data.init(base64URL:)), leader.count == 32,
              let exp = fields["exp"].flatMap(Int.init), exp > 0,
              fields["tag"] == SquadID(id).tag
        else { throw ParseError.malformed }
        var relay: RelayAddress?
        if let text = fields["relay"] {
            guard let address = RelayAddress(text: text, pin: fields["relay_pin"]) else { throw ParseError.malformed }
            relay = address
        } else if fields["relay_pin"] != nil {
            throw ParseError.malformed
        }
        self.init(squad: SquadID(id), name: name, enrol: enrol, leader: leader,
                  expires: Date(timeIntervalSince1970: TimeInterval(exp)), by: fields["by"].flatMap { $0.isEmpty ? nil : String($0.prefix(100)) }, relay: relay)
    }
}
