import Foundation
import CryptoKit

// Sealed links (docs/WIRE.md, "Sealed links"): what a link does when something that isn't one of
// its two ends carries it, like a relay. Each end sends a nonce in the clear; both derive two keys
// from the link key and the nonces; every frame after that is sealed with them. Whoever carries
// the link sees which key a device named and how long each frame is, and nothing else. It can't
// change, reorder, replay or add a frame without the link closing.

/// The first frame each end sends on a sealed link, in the clear.
public struct LinkSeal: Codable, Equatable, Sendable {
    /// From the device: the name of the key it holds. The leader's device sends none.
    public var id: String?
    /// 16 fresh random bytes.
    public var nonce: Data

    public init(id: String? = nil, nonce: Data = .random(SealedLink.nonceBytes)) {
        self.id = id
        self.nonce = nonce
    }
}

/// One end's keys for a sealed link. Frames must be opened in the order they were sealed.
public struct SealedLink {
    public enum Side: Sendable { case device, leader }
    public enum SealError: Error, Equatable {
        /// Not sealed with this link's key, or not the next frame.
        case cantOpen
    }

    public static let nonceBytes = 16
    /// Bytes a sealed frame is longer than what it holds.
    public static let overhead = 16

    private let sending: SymmetricKey
    private let receiving: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    /// - Parameters:
    ///   - carrier: what the carrier gave both ends for this link (a relay: its 32 bytes). Not
    ///     trusted; it only keeps two links apart.
    ///   - device: the device's nonce.
    ///   - leader: the leader's device's nonce.
    /// Nil if a nonce isn't 16 bytes.
    public init?(key: LinkKey, side: Side, carrier: Data, device: Data, leader: Data) {
        guard device.count == Self.nonceBytes, leader.count == Self.nonceBytes else { return nil }
        let both = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key.key), salt: device + leader,
                                          info: Data("squad sealed link v1".utf8) + carrier, outputByteCount: 64)
        let bytes = both.withUnsafeBytes { Data($0) }
        let fromDevice = SymmetricKey(data: bytes.prefix(32)), fromLeader = SymmetricKey(data: bytes.suffix(32))
        sending = side == .device ? fromDevice : fromLeader
        receiving = side == .device ? fromLeader : fromDevice
    }

    /// The ciphertext, then the 16-byte tag.
    public mutating func seal(_ plain: Data) throws -> Data {
        let box = try AES.GCM.seal(plain, using: sending, nonce: Self.nonce(sent))
        sent += 1
        // A copy, so the bytes count from 0.
        return Data(box.ciphertext) + box.tag
    }

    public mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= Self.overhead,
              let box = try? AES.GCM.SealedBox(nonce: Self.nonce(received), ciphertext: sealed.dropLast(Self.overhead),
                                               tag: sealed.suffix(Self.overhead)),
              let plain = try? AES.GCM.open(box, using: receiving) else { throw SealError.cantOpen }
        received += 1
        return plain
    }

    /// Four zero bytes, then the frame's count from 0, big-endian.
    private static func nonce(_ count: UInt64) -> AES.GCM.Nonce {
        // Twelve bytes is always a valid nonce.
        try! AES.GCM.Nonce(data: Data(count: 4) + count.bigEndianBytes)
    }
}
