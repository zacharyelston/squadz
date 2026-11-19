import Foundation

// What a squad needs to know about a relay (docs/RELAY.md). A relay carries a squad's links over
// the internet when its devices aren't on one network. It is a pipe: the leader's device is
// still the squad, and decides who is in it.

/// Where a relay is, and optionally which certificate it must show.
public struct RelayAddress: Codable, Hashable, Sendable {
    /// Like `wss://relay.example` or `wss://203.0.113.5:8443`. No path.
    public var url: URL
    /// SHA-256 of the relay's TLS certificate. With a pin, that certificate and no other is
    /// accepted, whoever signed it: the way to use a relay with a certificate of its own making.
    /// Without one, the certificate must check out the usual way.
    public var pin: Data?

    public init(url: URL, pin: Data? = nil) {
        self.url = url
        self.pin = pin
    }

    /// Reads what a person types or an invite carries. Only `wss` is taken: nothing goes to a
    /// relay in the clear.
    public init?(text: String, pin: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed.contains("://") ? trimmed : "wss://" + trimmed),
              c.scheme?.lowercased() == "wss", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { return nil }
        var clean = URLComponents()
        clean.scheme = "wss"
        clean.host = host.lowercased()
        clean.port = c.port
        guard let url = clean.url else { return nil }
        self.url = url
        if let pin = pin?.trimmingCharacters(in: .whitespacesAndNewlines), !pin.isEmpty {
            guard let bytes = Data(base64URL: pin), bytes.count == 32 else { return nil }
            self.pin = bytes
        }
    }

    public var text: String { url.absoluteString }
}

/// A device's pass for one squad's room on a relay. The relay hands it out to a device that
/// shows an open invite's relay key. It only opens a link to the leader's device, which still
/// asks for the member's credential.
public struct RelayTicket: Codable, Equatable, Sendable {
    public var address: RelayAddress
    /// The relay's name for this device. Not secret.
    public var device: String
    /// Secret. 32 bytes.
    public var token: Data

    public init(address: RelayAddress, device: String, token: Data) {
        self.address = address
        self.device = device
        self.token = token
    }
}

/// What the leader's device tells a relay about an open invite: enough to recognise a device
/// that holds it, and nothing that would let the relay join.
public struct RelayInvite: Hashable, Sendable {
    /// SHA-256 of the invite's relay key.
    public var hash: Data
    public var expires: Date
}

public extension SquadInvite {
    /// What a device shows a relay to get a ticket. It comes from the invite's secret and can't
    /// be turned back into it, so the relay never holds the key that enrols.
    var relayKey: Data { Self.relayKey(enrol: enrol) }

    static func relayKey(enrol: Data) -> Data {
        SquadCrypto.hmac(key: enrol, Data("squad relay join v1".utf8))
    }
}

public extension SquadCore {
    /// The open invites, as a relay should know them. Give these to the relay link again after
    /// anything that opens or closes joining.
    func relayInvites(now: Date) -> [RelayInvite] {
        invitations.filter { $0.expires > now }.map {
            RelayInvite(hash: SquadCrypto.sha256(SquadInvite.relayKey(enrol: $0.secret)), expires: $0.expires)
        }
    }
}
