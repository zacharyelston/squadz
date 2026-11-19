import Foundation

// Every message that crosses between devices (docs/WIRE.md).
//
// - A message's sender is the connection it arrived on (`PeerID`), never a field in the message.
// - Nothing a phone can send lifts a hold. Phones send positions, answers, notes and check fire;
//   the leader's device decides what to do with them.
// - A mission's messages ride in `.mission`, opaque to the core.

public struct SquadMessage: Equatable, Sendable {
    public var protocolVersion: Int
    /// Per-sender sequence number, from the transport.
    public var seq: Int
    public var body: Body

    public init(protocolVersion: Int = SquadProtocol.version, seq: Int, body: Body) {
        self.protocolVersion = protocolVersion
        self.seq = seq
        self.body = body
    }

    public enum Body: Equatable, Sendable {
        /// The first frame on a link, for the transport: which key the sender holds. The core
        /// never sees it.
        case link(LinkProof)
        /// The first frame each end sends on a link something else carries, like a relay: the
        /// nonces the link's keys are made from. The core never sees it.
        case seal(LinkSeal)

        // Member's phone → leader
        case hello(Hello)
        case bye
        case position(MemberPosition)
        case orderAck(OrderAck)
        /// Anyone → leader.
        case checkFire(CheckFire)
        /// Member → leader, who passes it on to observers.
        case note(FieldNote)
        /// A file in chunks, then done.
        case fileOffer(FileOffer)
        case fileChunk(FileChunk)
        case fileDone(UUID)

        // Leader → member's phone (and to observers: status, positions, orders and notes only)
        /// To a device on an invite link: its credential. The link closes after it.
        case enrolled(Enrolled)
        /// The leader's device has a new identity key.
        case leaderKey(LeaderKeyChange)
        case welcome(Welcome)
        /// To a watcher that joined as an observer.
        case observing(Squad)
        case refused(String)
        case status(SquadStatus)
        case order(Order)
        /// What the receiver did with a note or a file.
        case receipt(Receipt)
        /// Leader → observers.
        case positions(PositionsReport)

        /// Either way: a mission's own message.
        case mission(MissionMessage)
    }
}

extension SquadMessage: Codable {
    private enum Keys: String, CodingKey { case v, seq, type, body }
    private struct FileRef: Codable { var file: UUID }
    private struct Reason: Codable { var reason: String }

    /// The `type` on the wire.
    public var type: String {
        switch body {
        case .link: return "link"
        case .seal: return "seal"
        case .enrolled: return "enrolled"
        case .leaderKey: return "leaderKey"
        case .hello: return "hello"
        case .bye: return "bye"
        case .position: return "position"
        case .orderAck: return "orderAck"
        case .checkFire: return "checkFire"
        case .note: return "note"
        case .fileOffer: return "fileOffer"
        case .fileChunk: return "fileChunk"
        case .fileDone: return "fileDone"
        case .welcome: return "welcome"
        case .observing: return "observing"
        case .refused: return "refused"
        case .status: return "status"
        case .order: return "order"
        case .receipt: return "receipt"
        case .positions: return "positions"
        case .mission: return "mission"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(protocolVersion, forKey: .v)
        try c.encode(seq, forKey: .seq)
        try c.encode(type, forKey: .type)
        switch body {
        case .bye: break
        case let .link(x): try c.encode(x, forKey: .body)
        case let .seal(x): try c.encode(x, forKey: .body)
        case let .enrolled(x): try c.encode(x, forKey: .body)
        case let .leaderKey(x): try c.encode(x, forKey: .body)
        case let .hello(x): try c.encode(x, forKey: .body)
        case let .position(x): try c.encode(x, forKey: .body)
        case let .orderAck(x): try c.encode(x, forKey: .body)
        case let .checkFire(x): try c.encode(x, forKey: .body)
        case let .note(x): try c.encode(x, forKey: .body)
        case let .fileOffer(x): try c.encode(x, forKey: .body)
        case let .fileChunk(x): try c.encode(x, forKey: .body)
        case let .fileDone(x): try c.encode(FileRef(file: x), forKey: .body)
        case let .welcome(x): try c.encode(x, forKey: .body)
        case let .observing(x): try c.encode(x, forKey: .body)
        case let .refused(x): try c.encode(Reason(reason: x), forKey: .body)
        case let .status(x): try c.encode(x, forKey: .body)
        case let .order(x): try c.encode(x, forKey: .body)
        case let .receipt(x): try c.encode(x, forKey: .body)
        case let .positions(x): try c.encode(x, forKey: .body)
        case let .mission(x): try c.encode(x, forKey: .body)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        protocolVersion = try c.decode(Int.self, forKey: .v)
        seq = try c.decode(Int.self, forKey: .seq)
        let type = try c.decode(String.self, forKey: .type)
        func value<T: Decodable>(_: T.Type = T.self) throws -> T { try c.decode(T.self, forKey: .body) }
        switch type {
        case "link": body = .link(try value())
        case "seal": body = .seal(try value())
        case "enrolled": body = .enrolled(try value())
        case "leaderKey": body = .leaderKey(try value())
        case "hello": body = .hello(try value())
        case "bye": body = .bye
        case "position": body = .position(try value())
        case "orderAck": body = .orderAck(try value())
        case "checkFire": body = .checkFire(try value())
        case "note": body = .note(try value())
        case "fileOffer": body = .fileOffer(try value())
        case "fileChunk": body = .fileChunk(try value())
        case "fileDone": body = .fileDone(try value(FileRef.self).file)
        case "welcome": body = .welcome(try value())
        case "observing": body = .observing(try value())
        case "refused": body = .refused(try value(Reason.self).reason)
        case "status": body = .status(try value())
        case "order": body = .order(try value())
        case "receipt": body = .receipt(try value())
        case "positions": body = .positions(try value())
        case "mission": body = .mission(try value())
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown message type \(type)")
        }
    }
}

/// A message to send, with the peer it goes to.
public struct Outgoing: Equatable, Sendable {
    public var to: PeerID
    public var body: SquadMessage.Body
    /// The transport closes the link once this is sent: an invite link after its answer, or a
    /// member who was removed.
    public var thenClose: Bool
    public init(to: PeerID, _ body: SquadMessage.Body, thenClose: Bool = false) {
        self.to = to
        self.body = body
        self.thenClose = thenClose
    }

    /// One of mission `M`'s own messages.
    public static func mission<M: Mission>(_: M.Type, to: PeerID, _ payload: Data) -> Outgoing {
        Outgoing(to: to, .mission(MissionMessage(id: M.id, version: M.version, payload: payload)))
    }
}
