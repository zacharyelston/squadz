import Foundation
import CryptoKit

// Who may connect, and as whom (docs/WIRE.md, "Joining").
//
// - An invite (a QR code, or the typed code on local Wi-Fi) lets a new device in once. The
//   leader's device answers with a member credential, sealed to that device.
// - From then on the device connects with its credential. The leader derives every credential's
//   secret from one root key, so its roster holds no secrets.
// - The leader's device signs what it hands out with its identity key. The invite carries that
//   key's fingerprint, so another device advertising the same squad name can't pass.

// MARK: Bytes

extension UUID {
    /// The 16 bytes, in the order the string shows them.
    var bytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

extension FixedWidthInteger {
    var bigEndianBytes: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}

extension Date {
    /// Whole milliseconds since 1970, as the wire carries dates.
    var wireMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    var roundedToWire: Date { Date(timeIntervalSince1970: Double(wireMilliseconds) / 1000) }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        self = out
    }

    /// Base64 for URLs: `-` and `_`, no padding.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard s.count % 4 != 1 else { return nil }
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        guard let d = Data(base64Encoded: s) else { return nil }
        self = d
    }

    static func random(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }
}

enum SquadCrypto {
    static func hkdf(_ secret: Data, salt: Data, info: String, extra: Data = Data()) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                                         info: Data(info.utf8) + extra, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    static func hmac(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

public extension SquadID {
    /// Eight hex characters that find this squad again whatever it is called: the first four
    /// bytes of SHA-256 of the ID. Advertised in the Bonjour TXT record and carried in invites.
    var tag: String { SquadCrypto.sha256(raw.bytes).prefix(4).hex }
}

// MARK: Link keys

/// The key for one link, and the name the connecting device gives for it. The transport turns it
/// into its own key (SquadLink: a TLS pre-shared key).
public struct LinkKey: Hashable, Sendable {
    public var identity: String
    public var key: Data

    public init(identity: String, key: Data) {
        self.identity = identity
        self.key = key
    }

    /// The typed code. About 30 bits: for local Wi-Fi only, and only while joining is open.
    public static func code(_ code: String) -> LinkKey {
        LinkKey(identity: "code", key: SquadCrypto.hmac(key: Data(JoinCode.normalized(code).utf8), Data("squad code link".utf8)))
    }

    /// An invite's secret (from the QR code).
    public static func invite(secret: Data, squad: SquadID) -> LinkKey {
        LinkKey(identity: "e:" + SquadCrypto.sha256(secret).prefix(8).hex,
                key: SquadCrypto.hkdf(secret, salt: squad.raw.bytes, info: "squad enrol link"))
    }

    /// A member credential.
    public static func member(credential id: Data, secret: Data, squad: SquadID) -> LinkKey {
        LinkKey(identity: "m:" + id.hex, key: SquadCrypto.hkdf(secret, salt: squad.raw.bytes, info: "squad member link"))
    }

    /// Proves the sender holds this key, on this connection. `binding` is a value both ends of
    /// the connection share and nobody else can choose (SquadLink: a TLS exporter).
    public func proof(binding: Data) -> Data {
        SquadCrypto.hmac(key: key, Data("squad link proof v1".utf8) + binding)
    }

    public func accepts(_ proof: Data, binding: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("squad link proof v1".utf8) + binding,
                                               using: SymmetricKey(data: key))
    }
}

/// The first frame on a link: which key the sender used, and proof that it holds it.
public struct LinkProof: Codable, Equatable, Sendable {
    public var id: String
    public var proof: Data
    public init(id: String, proof: Data) {
        self.id = id
        self.proof = proof
    }
}

// MARK: The leader's keys

/// What the leader's device keeps secret, in its Keychain: the root every member secret comes
/// from, and the key that proves this device is the squad's leader.
public struct LeaderKeys {
    /// 32 bytes.
    public var root: Data
    public var identity: P256.Signing.PrivateKey

    public init() {
        root = .random(32)
        identity = P256.Signing.PrivateKey()
    }

    /// From what `exported` gave.
    public init(root: Data, identity: Data) throws {
        guard root.count == 32 else { throw EnrolmentError.badCredential }
        self.root = root
        self.identity = try P256.Signing.PrivateKey(rawRepresentation: identity)
    }

    /// For the Keychain. Never for a file or a message.
    public var exported: (root: Data, identity: Data) { (root, identity.rawRepresentation) }

    /// The identity key's public half, X9.63 (65 bytes).
    public var publicKey: Data { identity.publicKey.x963Representation }
    public var fingerprint: Data { Self.fingerprint(of: publicKey) }

    /// SHA-256 of the X9.63 public key.
    public static func fingerprint(of publicKey: Data) -> Data { SquadCrypto.sha256(publicKey) }

    public func memberSecret(squad: SquadID, credential id: Data, epoch: Int) -> Data {
        SquadCrypto.hkdf(root, salt: squad.raw.bytes, info: "member", extra: id + UInt32(epoch).bigEndianBytes)
    }

    func sign(_ data: Data) -> Data {
        // P-256 signing with a key held in memory doesn't fail.
        (try? identity.signature(for: data).rawRepresentation) ?? Data()
    }

    static func verify(_ signature: Data, of data: Data, by publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: data)
    }
}

// MARK: Credentials

/// What a device keeps, in its Keychain, to connect to one squad again.
public struct MemberCredential: Codable, Equatable, Sendable {
    public var squad: SquadID
    /// For the device's own list of squads. The leader may rename the squad later.
    public var squadName: String
    /// Nil for an observer.
    public var member: MemberID?
    public var role: Hello.Role
    /// Public. 16 bytes.
    public var id: Data
    /// Secret. 32 bytes.
    public var secret: Data
    public var epoch: Int
    public var issued: Date
    /// The leader's identity key (X9.63), as pinned when joining.
    public var leader: Data

    public var linkKey: LinkKey { .member(credential: id, secret: secret, squad: squad) }

    /// Follows the leader to a new identity key, if the pinned key signed the change.
    public mutating func apply(_ change: LeaderKeyChange) -> Bool {
        guard change.squad == squad, change.key != leader,
              LeaderKeys.verify(change.signature, of: change.signed, by: leader) else { return false }
        leader = change.key
        return true
    }
}

/// The leader's note of a credential it issued. No secrets: safe to save in a file.
public struct CredentialRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: Data
    /// Nil for an observer.
    public var member: MemberID?
    public var role: Hello.Role
    public var name: String
    public var device: UUID
    public var epoch: Int
    public var issued: Date
    public var revoked: Bool
}

/// A credential on its way to the device it is for, readable only by that device.
public struct SealedCredential: Codable, Equatable, Sendable {
    public var id: Data
    public var epoch: Int
    public var issued: Date
    /// The leader's one-time P-256 key (X9.63).
    public var key: Data
    /// AES-256-GCM: 12-byte nonce, the 32-byte secret encrypted, 16-byte tag.
    public var sealed: Data

    static func sealingKey(shared: SharedSecret, squad: SquadID, leaderKey: Data, memberKey: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: squad.raw.bytes,
                                       sharedInfo: Data("squad credential v1".utf8) + leaderKey + memberKey, outputByteCount: 32)
    }

    static func seal(secret: Data, id: Data, epoch: Int, issued: Date, squad: SquadID, for memberKey: Data,
                     oneTime: P256.KeyAgreement.PrivateKey = .init(), nonce: AES.GCM.Nonce = .init()) throws -> SealedCredential {
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: memberKey)
        let mine = oneTime.publicKey.x963Representation
        let key = sealingKey(shared: try oneTime.sharedSecretFromKeyAgreement(with: theirs), squad: squad, leaderKey: mine, memberKey: memberKey)
        let box = try AES.GCM.seal(secret, using: key, nonce: nonce, authenticating: id)
        guard let combined = box.combined else { throw EnrolmentError.badCredential }
        return SealedCredential(id: id, epoch: epoch, issued: issued, key: mine, sealed: combined)
    }

    func open(squad: SquadID, with memberKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: key)
        let k = Self.sealingKey(shared: try memberKey.sharedSecretFromKeyAgreement(with: theirs), squad: squad,
                                leaderKey: key, memberKey: memberKey.publicKey.x963Representation)
        let secret = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: k, authenticating: id)
        guard secret.count == 32 else { throw EnrolmentError.badCredential }
        return secret
    }
}

/// Leader → a device on an invite link: you're in, and here is your credential. The link closes
/// after this; the device connects again with the credential.
public struct Enrolled: Codable, Equatable, Sendable {
    public var squad: SquadID
    public var name: String
    /// Nil for an observer.
    public var member: MemberID?
    public var role: Hello.Role
    public var credential: SealedCredential
    /// The leader's identity key (X9.63).
    public var leader: Data
    /// By `leader`, over `signed(...)`: ECDSA P-256 with SHA-256, as 64 bytes (r, then s).
    public var signature: Data

    /// What the signature covers. Every field has a fixed length.
    static func signed(squad: SquadID, member: MemberID?, role: Hello.Role, nonce: Data, memberKey: Data,
                       credential c: SealedCredential) -> Data {
        var d = Data("squad enrolled v1".utf8)
        d += squad.raw.bytes
        d += member?.raw.bytes ?? Data(count: 16)
        d.append(role == .observer ? 1 : 0)
        d += nonce
        d += memberKey
        d += c.id
        d += UInt32(c.epoch).bigEndianBytes
        d += UInt64(c.issued.wireMilliseconds).bigEndianBytes
        d += c.key
        d += c.sealed
        return d
    }
}

/// The leader's device moved to a new identity key. Signed by the old one, so devices that pinned
/// the old key follow.
public struct LeaderKeyChange: Codable, Equatable, Sendable {
    public var squad: SquadID
    /// The new key (X9.63).
    public var key: Data
    public var time: Date
    /// By the key this replaces.
    public var signature: Data

    var signed: Data {
        Data("squad leader key v1".utf8) + squad.raw.bytes + key + UInt64(time.wireMilliseconds).bigEndianBytes
    }

    init(squad: SquadID, key: Data, time: Date, signature: Data) {
        self.squad = squad
        self.key = key
        self.time = time
        self.signature = signature
    }

    init(squad: SquadID, to new: Data, time: Date, signedBy old: LeaderKeys) {
        self.squad = squad
        key = new
        self.time = time.roundedToWire
        signature = Data()
        signature = old.sign(signed)
    }
}

public enum EnrolmentError: Error, Equatable {
    /// The answer is for another squad than the invite's.
    case wrongSquad
    /// The device that answered isn't the leader the invite named.
    case wrongLeader
    case badSignature
    case badCredential
    case expired
}

/// A device asking to join. Make one, send its `hello` on an invite link, and give the answer to
/// `accept`.
public struct EnrolmentRequest {
    public let hello: Hello
    let key: P256.KeyAgreement.PrivateKey

    public init(name: String, device: UUID, role: Hello.Role? = nil) {
        self.init(name: name, device: device, role: role, key: .init(), nonce: .random(16))
    }

    init(name: String, device: UUID, role: Hello.Role?, key: P256.KeyAgreement.PrivateKey, nonce: Data) {
        self.key = key
        hello = Hello(name: name, device: device, role: role, nonce: nonce, key: key.publicKey.x963Representation)
    }

    /// Checks the leader's answer and opens the credential. With an invite from a QR code, the
    /// answer must come from the leader the invite names. With a typed code there is nothing to
    /// check the leader against: the key that answers is the one pinned.
    public func accept(_ e: Enrolled, invite: SquadInvite?) throws -> MemberCredential {
        if let invite {
            guard e.squad == invite.squad else { throw EnrolmentError.wrongSquad }
            guard LeaderKeys.fingerprint(of: e.leader) == invite.leader else { throw EnrolmentError.wrongLeader }
        }
        let signed = Enrolled.signed(squad: e.squad, member: e.member, role: e.role, nonce: hello.nonce,
                                     memberKey: hello.key ?? Data(), credential: e.credential)
        guard LeaderKeys.verify(e.signature, of: signed, by: e.leader) else { throw EnrolmentError.badSignature }
        guard e.credential.id.count == 16, (e.member == nil) == (e.role == .observer),
              let secret = try? e.credential.open(squad: e.squad, with: key) else { throw EnrolmentError.badCredential }
        return MemberCredential(squad: e.squad, squadName: e.name, member: e.member, role: e.role, id: e.credential.id,
                                secret: secret, epoch: e.credential.epoch, issued: e.credential.issued, leader: e.leader)
    }
}
