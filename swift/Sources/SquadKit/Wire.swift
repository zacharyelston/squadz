import Foundation

/// Length-prefixed JSON frames: a 4-byte big-endian length, then a `SquadMessage` as JSON
/// (docs/WIRE.md). The same framing runs over TCP and the loopback.
public enum SquadWire {
    /// Larger frames are refused.
    public static let maxFrameBytes = 1 << 20

    public enum WireError: Error, Equatable {
        case frameTooLarge(Int)
        case undecodable(String)
    }

    public static func encode(_ message: SquadMessage) throws -> Data {
        let json = try encoder.encode(message)
        guard json.count <= maxFrameBytes else { throw WireError.frameTooLarge(json.count) }
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Accumulates bytes as they arrive and returns whole messages.
    public struct FrameReader {
        private var buffer = Data()
        public init() {}

        public mutating func append(_ bytes: Data) throws -> [SquadMessage] {
            buffer.append(bytes)
            var out: [SquadMessage] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length <= maxFrameBytes else { buffer.removeAll(); throw WireError.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let json = buffer.dropFirst(4).prefix(length)
                buffer = Data(buffer.dropFirst(4 + length))
                do {
                    out.append(try decoder.decode(SquadMessage.self, from: Data(json)))
                } catch {
                    throw WireError.undecodable(String(describing: error))
                }
            }
            return out
        }
    }

    /// Dates are milliseconds since 1970; keys are sorted so the same message is the same bytes.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()
}
