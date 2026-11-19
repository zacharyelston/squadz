import Foundation
import CryptoKit
import XCTest
@testable import SquadKit

/// Joining (docs/WIRE.md, "Joining"): invites, credentials, and the leader's identity key.
final class JoinTests: XCTestCase {
    static let vectors = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testdata/join/vectors.json")

    // MARK: Invites

    func testAnInviteSurvivesItsLink() throws {
        var host = SquadCore(squad: Squad(name: "Red & Blue / ✓"), mission: NoMission())
        let now = Date(timeIntervalSince1970: 1_800_000_000.7)
        let invite = host.openJoining(now: now, by: "Club iPad")
        let url = invite.url(scheme: "squadz")
        XCTAssertEqual(try SquadInvite(url: url, scheme: "squadz"), invite)
        XCTAssertEqual(invite.expires.timeIntervalSince1970, 1_800_000_900)
        XCTAssertFalse(invite.isExpired(now: now.addingTimeInterval(899)))
        XCTAssertTrue(invite.isExpired(now: now.addingTimeInterval(900)))
        XCTAssertEqual(invite.leader, host.keys.fingerprint)

        // It carries no long-term key.
        let text = url.absoluteString
        XCTAssertFalse(text.contains(host.keys.root.base64URL))
        XCTAssertFalse(text.contains(host.keys.identity.rawRepresentation.base64URL))
        XCTAssertEqual(Set(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map(\.name)),
                       ["v", "squad", "name", "enrol", "cmd", "tag", "exp", "by"])
    }

    func testBadInviteLinksAreRefused() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let good = host.openJoining(now: Date()).url(scheme: "squadz").absoluteString
        func parse(_ text: String) throws -> SquadInvite { try SquadInvite(url: try XCTUnwrap(URL(string: text)), scheme: "squadz") }
        XCTAssertNoThrow(try parse(good))
        XCTAssertThrowsError(try parse(good.replacingOccurrences(of: "squadz://", with: "spudgolf://"))) {
            XCTAssertEqual($0 as? SquadInvite.ParseError, .notAnInvite)
        }
        XCTAssertThrowsError(try parse(good.replacingOccurrences(of: "://join", with: "://pair")))
        XCTAssertThrowsError(try parse(good.replacingOccurrences(of: "v=1", with: "v=2"))) {
            XCTAssertEqual($0 as? SquadInvite.ParseError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try parse(good.replacingOccurrences(of: "tag=", with: "tag=0")), "a tag for another squad")
        XCTAssertThrowsError(try parse(good.replacingOccurrences(of: "enrol=", with: "enrol=AAAA")), "a secret of the wrong length")
        XCTAssertThrowsError(try parse(good + "&squad=" + UUID().uuidString), "a field given twice")
        for field in ["squad", "name", "enrol", "cmd", "tag", "exp"] {
            XCTAssertThrowsError(try parse(good.replacingOccurrences(of: "\(field)=", with: "x\(field)=")), "no \(field)")
        }
        XCTAssertThrowsError(try parse("https://example.com/join?v=1"))
    }

    // MARK: Joining

    /// The whole join, message by message, with the checks a joining device makes.
    func testJoinByInviteThenReconnectByCredential() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = host.openJoining(now: now)
        XCTAssertEqual(host.linkKeys(now: now), [invite.linkKey])

        let door = PeerID("door"), link = PeerID("link")
        let request = EnrolmentRequest(name: "Ana", device: UUID())
        host.linkOpened(door, identity: invite.linkKey.identity)
        let out = host.handle(SquadMessage(seq: 1, body: .hello(request.hello)), from: door, now: now)
        guard case let .enrolled(answer)? = out.first?.body else { return XCTFail("\(out)") }
        XCTAssertTrue(out[0].thenClose, "an invite link closes after its answer")
        XCTAssertTrue(host.peers.isEmpty, "not connected until it comes back on its credential")

        let credential = try request.accept(answer, invite: invite)
        XCTAssertEqual(credential.secret, host.keys.memberSecret(squad: host.squadID, credential: credential.id, epoch: 0))
        XCTAssertEqual(credential.leader, host.keys.publicKey)
        XCTAssertTrue(host.linkKeys(now: now).contains(credential.linkKey))

        // The roster the leader saves holds no secret.
        let saved = String(decoding: try JSONEncoder().encode(host.credentials), as: UTF8.self)
        XCTAssertFalse(saved.contains(credential.secret.base64EncodedString()))

        // What an invite link sends besides hello is ignored.
        XCTAssertTrue(host.handle(SquadMessage(seq: 2, body: .checkFire(CheckFire(by: "Ana"))), from: door, now: now).isEmpty)
        XCTAssertTrue(host.holds(now: now).isEmpty)
        host.peerClosed(door)

        host.linkOpened(link, identity: credential.linkKey.identity)
        let back = host.handle(SquadMessage(seq: 1, body: .hello(Hello(name: "Someone else", device: UUID()))), from: link, now: now)
        guard case let .welcome(w)? = back.first?.body else { return XCTFail("\(back)") }
        XCTAssertEqual(w.member, credential.member, "who it is comes from the credential, not the hello")
        XCTAssertEqual(host.squad.members.map(\.name), ["Ana"])
    }

    func testAnswersThatDontCheckOutAreRefused() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let now = Date()
        let invite = host.openJoining(now: now)
        let request = EnrolmentRequest(name: "Ana", device: UUID())
        func answer(from core: inout SquadCore<NoMission>, to hello: Hello, on key: LinkKey) throws -> Enrolled {
            let peer = PeerID(UUID().uuidString)
            core.linkOpened(peer, identity: key.identity)
            guard case let .enrolled(e)? = core.handle(SquadMessage(seq: 1, body: .hello(hello)), from: peer, now: now).first?.body
            else { throw EnrolmentError.badCredential }
            return e
        }
        let good = try answer(from: &host, to: request.hello, on: invite.linkKey)
        XCTAssertNoThrow(try request.accept(good, invite: invite))

        // Another device that advertises the same squad, and even holds the invite's secret: it
        // has its own identity key, not the one the invite names.
        var rogue = SquadCore(squad: Squad(id: host.squadID, name: "Red"), mission: NoMission())
        _ = rogue.openJoining(now: now)
        let rogueKey = rogue.linkKeys(now: now)[0]
        let forged = try answer(from: &rogue, to: request.hello, on: rogueKey)
        XCTAssertThrowsError(try request.accept(forged, invite: invite)) { XCTAssertEqual($0 as? EnrolmentError, .wrongLeader) }

        // The right leader's key pasted onto the rogue's answer: the signature doesn't hold.
        var pasted = forged
        pasted.leader = good.leader
        XCTAssertThrowsError(try request.accept(pasted, invite: invite)) { XCTAssertEqual($0 as? EnrolmentError, .badSignature) }

        // An answer the leader gave someone else (a replay): signed for their nonce and key.
        let other = EnrolmentRequest(name: "Ben", device: UUID())
        let theirs = try answer(from: &host, to: other.hello, on: invite.linkKey)
        XCTAssertThrowsError(try request.accept(theirs, invite: invite)) { XCTAssertEqual($0 as? EnrolmentError, .badSignature) }

        // Any field changed on the way.
        var renamed = good
        renamed.member = MemberID()
        XCTAssertThrowsError(try request.accept(renamed, invite: invite))
        var resealed = good
        resealed.credential.sealed[20] ^= 1
        XCTAssertThrowsError(try request.accept(resealed, invite: invite))

        // Someone who recorded the whole join and has the invite's secret still can't open the
        // credential: it is sealed to the joining device's one-time key.
        let eavesdropper = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try good.credential.open(squad: host.squadID, with: eavesdropper))
    }

    func testExpiredUsedAndClosedInvitesAreRefused() throws {
        let y = Yard(mission: NoMission())
        func refused(_ name: String) -> Bool { y.has(name) { if case .refused = $0 { return true }; return false } }

        // Expired.
        _ = y.invite
        y.now += 15 * 60
        XCTAssertNil(y.join("Late"))
        XCTAssertTrue(refused("Late"))
        XCTAssertTrue(y.host.linkKeys(now: y.now).isEmpty, "an expired invite isn't offered to the transport either")

        // One person each.
        y.invite = y.host.inviteOne(now: y.now)
        XCTAssertNotNil(y.join("Ana"))
        XCTAssertNil(y.join("Ben"))
        XCTAssertTrue(refused("Ben"))

        // Closed by the leader. Ana, already in, isn't affected.
        y.invite = y.host.openJoining(now: y.now, typedCode: true)
        XCTAssertNotNil(y.host.joinCode)
        y.host.closeJoining()
        XCTAssertNil(y.host.joinCode)
        XCTAssertNil(y.join("Cy"))
        XCTAssertTrue(refused("Cy"))
        y.send("Ana", .bye)
        XCTAssertNotNil(y.join("Ana"))
        XCTAssertEqual(y.host.squad.members.map(\.name), ["Ana"])
    }

    func testTheTypedCodeJoinsWhileJoiningIsOpen() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let now = Date()
        _ = host.openJoining(now: now, typedCode: true)
        let code = try XCTUnwrap(host.joinCode)
        XCTAssertTrue(host.linkKeys(now: now).contains(.code(code.lowercased())))

        let request = EnrolmentRequest(name: "Ana", device: UUID())
        host.linkOpened(PeerID("p"), identity: "code")
        guard case let .enrolled(answer)? = host.handle(SquadMessage(seq: 1, body: .hello(request.hello)), from: PeerID("p"), now: now).first?.body
        else { return XCTFail() }
        // No invite to check the leader against: the key that answered is pinned.
        XCTAssertEqual(try request.accept(answer, invite: nil).leader, host.keys.publicKey)

        host.linkOpened(PeerID("q"), identity: "code")
        let late = host.handle(SquadMessage(seq: 1, body: .hello(EnrolmentRequest(name: "Ben", device: UUID()).hello)),
                               from: PeerID("q"), now: now.addingTimeInterval(15 * 60))
        XCTAssertEqual(late.map(\.body), [.refused("Joining is closed.")])
    }

    func testAnObserverGetsAnObserverCredential() throws {
        let y = Yard(mission: NoMission())
        XCTAssertNil(y.join("Watcher", role: .observer), "an observer isn't a member")
        let credential = try XCTUnwrap(y.credentials["Watcher"])
        XCTAssertEqual(credential.role, .observer)
        XCTAssertTrue(y.has("Watcher") { if case .observing = $0 { return true }; return false })
        XCTAssertTrue(y.host.squad.members.isEmpty)

        // Asking to be a member on an observer's credential changes nothing.
        y.host.peerClosed(y.peer("Watcher"))
        y.host.linkOpened(y.peer("Watcher"), identity: credential.linkKey.identity)
        y.send("Watcher", .hello(Hello(name: "Watcher", device: UUID(), role: .member)))
        XCTAssertTrue(y.host.squad.members.isEmpty)
        XCTAssertEqual(y.host.observers, [y.peer("Watcher")])

        y.command { core, now in core.revoke(credential: credential.id, now: now) }
        XCTAssertTrue(y.host.observers.isEmpty)
        XCTAssertTrue(y.has("Watcher") { $0 == .refused("Removed from the squad.") })
    }

    func testResetSquadEndsEveryCredential() throws {
        let y = Yard(mission: NoMission())
        y.join("Ana")
        let old = try XCTUnwrap(y.credentials["Ana"])
        y.command { core, now in core.resetSquad(now: now) }
        XCTAssertTrue(y.has("Ana") { if case .refused = $0 { return true }; return false })
        XCTAssertTrue(y.host.squad.members.isEmpty)
        XCTAssertTrue(y.host.linkKeys(now: y.now).isEmpty)
        y.join("Ana")   // the old credential
        XCTAssertTrue(y.host.peers.isEmpty)

        // Joining again gives a credential under the new root.
        y.credentials["Ana"] = nil
        y.invite = y.host.openJoining(now: y.now)
        XCTAssertNotNil(y.join("Ana"))
        let new = try XCTUnwrap(y.credentials["Ana"])
        XCTAssertEqual(new.epoch, 1)
        XCTAssertNotEqual(new.secret, old.secret)
    }

    func testALeaderReadBackFromItsSavedRosterAcceptsItsMembers() throws {
        let y = Yard(mission: NoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        let exported = y.host.keys.exported
        let roster = try JSONEncoder().encode(y.host.credentials)

        var again = SquadCore(squad: y.host.squad, mission: NoMission(),
                              keys: try LeaderKeys(root: exported.root, identity: exported.identity),
                              credentials: try JSONDecoder().decode([CredentialRecord].self, from: roster))
        let credential = try XCTUnwrap(y.credentials["Ana"])
        XCTAssertEqual(again.linkKeys(now: y.now), [credential.linkKey])
        again.linkOpened(PeerID("p"), identity: credential.linkKey.identity)
        guard case let .welcome(w)? = again.handle(SquadMessage(seq: 1, body: .hello(Hello(name: "Ana", device: UUID()))),
                                                   from: PeerID("p"), now: y.now).first?.body else { return XCTFail() }
        XCTAssertEqual(w.member, ana)
    }

    // MARK: The leader's identity key

    func testANewIdentityKeyIsFollowedOnlyWhenTheOldKeySignedIt() throws {
        let y = Yard(mission: NoMission())
        y.join("Ana")
        y.join("Ben")
        y.send("Ben", .bye)   // Ben is away for the change
        var ana = try XCTUnwrap(y.credentials["Ana"]), ben = try XCTUnwrap(y.credentials["Ben"])
        let first = y.host.keys.publicKey

        let next = LeaderKeys()
        y.command { core, now in core.changeIdentity(to: next, now: now) }
        XCTAssertEqual(y.host.keys.publicKey, next.publicKey)
        XCTAssertTrue(y.host.invitations.isEmpty, "invites naming the old key are closed")

        func changes(_ name: String) -> [LeaderKeyChange] {
            y.got[name, default: []].compactMap { if case let .leaderKey(c) = $0 { return c } else { return nil } }
        }
        XCTAssertEqual(changes("Ana").count, 1)
        XCTAssertTrue(ana.apply(changes("Ana")[0]))
        XCTAssertEqual(ana.leader, next.publicKey)
        XCTAssertFalse(ana.apply(changes("Ana")[0]), "once")

        // Ben gets it when he comes back, before the welcome.
        XCTAssertTrue(changes("Ben").isEmpty)
        y.join("Ben")
        XCTAssertTrue(ben.apply(try XCTUnwrap(changes("Ben").first)))

        // A change the pinned key didn't sign: someone else's key, or a signed change edited.
        var cy = ben
        cy.leader = first
        let stranger = LeaderKeys()
        XCTAssertFalse(cy.apply(LeaderKeyChange(squad: cy.squad, to: stranger.publicKey, time: y.now, signedBy: stranger)))
        var edited = changes("Ana")[0]
        edited.key = stranger.publicKey
        XCTAssertFalse(cy.apply(edited))
        XCTAssertEqual(cy.leader, first)

        // New invites name the new key.
        XCTAssertEqual(y.host.openJoining(now: y.now).leader, next.fingerprint)
    }

    // MARK: Shared vectors

    struct Vectors: Codable, Equatable {
        var squad: String
        var tag: String
        var root: String
        var credentialID: String
        var epoch: Int
        var memberSecret: String
        var memberLink: Link
        var inviteSecret: String
        var inviteLink: Link
        var code: String
        var codeLink: Link
        var binding: String
        var memberProof: String
        var identityPrivate: String
        var identityPublic: String
        var fingerprint: String
        var inviteURL: String
        var memberOneTimePrivate: String
        var hello: String
        var enrolled: String
        var leaderKeyChange: String
        struct Link: Codable, Equatable { var identity: String; var key: String }
    }

    /// Fixed inputs and what every implementation must derive from them. Signatures differ each
    /// time they are made, so `enrolled` and `leaderKeyChange` are checked, not compared.
    func testDerivationsMatchTheSharedVectors() throws {
        func bytes(_ n: UInt8, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: Int(n) + $0) }) }
        func link(_ k: LinkKey) -> Vectors.Link { .init(identity: k.identity, key: k.key.hex) }
        func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try SquadWire.encoder.encode(v), as: UTF8.self) }
        let squad = SquadID(uuid(1))
        let keys = try LeaderKeys(root: bytes(1, 32), identity: bytes(40, 32))
        let id = bytes(100, 16), enrol = bytes(120, 16), binding = bytes(200, 32)
        let secret = keys.memberSecret(squad: squad, credential: id, epoch: 3)
        let memberLink = LinkKey.member(credential: id, secret: secret, squad: squad)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = SquadInvite(squad: squad, name: "Red Squad", enrol: enrol, leader: keys.fingerprint, expires: t, by: "Club iPad")
        let memberKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes(60, 32))
        let request = EnrolmentRequest(name: "Ana", device: uuid(3), role: nil, key: memberKey, nonce: bytes(140, 16))
        let member = MemberID(uuid(2))

        let made: Vectors = try {
            let sealed = try SealedCredential.seal(secret: secret, id: id, epoch: 3, issued: t, squad: squad, for: request.hello.key!,
                                                   oneTime: try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes(80, 32)),
                                                   nonce: try AES.GCM.Nonce(data: bytes(160, 12)))
            let signature = keys.sign(Enrolled.signed(squad: squad, member: member, role: .member, nonce: request.hello.nonce,
                                                      memberKey: request.hello.key!, credential: sealed))
            let enrolled = Enrolled(squad: squad, name: "Red Squad", member: member, role: .member, credential: sealed,
                                    leader: keys.publicKey, signature: signature)
            let next = try LeaderKeys(root: keys.root, identity: bytes(90, 32))
            return Vectors(squad: squad.raw.uuidString, tag: squad.tag, root: keys.root.hex, credentialID: id.hex, epoch: 3,
                           memberSecret: secret.hex, memberLink: link(memberLink),
                           inviteSecret: enrol.hex, inviteLink: link(invite.linkKey),
                           code: "RED234", codeLink: link(.code("RED234")),
                           binding: binding.hex, memberProof: memberLink.proof(binding: binding).hex,
                           identityPrivate: keys.identity.rawRepresentation.hex, identityPublic: keys.publicKey.hex,
                           fingerprint: keys.fingerprint.hex, inviteURL: invite.url(scheme: "squadz").absoluteString,
                           memberOneTimePrivate: memberKey.rawRepresentation.hex,
                           hello: try json(request.hello), enrolled: try json(enrolled),
                           leaderKeyChange: try json(LeaderKeyChange(squad: squad, to: next.publicKey, time: t, signedBy: keys)))
        }()
        if ProcessInfo.processInfo.environment["UPDATE_VECTORS"] == "1" {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: Self.vectors.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.encode(made).write(to: Self.vectors)
        }
        let saved = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: Self.vectors))
        var comparable = made
        comparable.enrolled = saved.enrolled
        comparable.leaderKeyChange = saved.leaderKeyChange
        XCTAssertEqual(comparable, saved, "a derivation changed: rerun with UPDATE_VECTORS=1 and say so in docs/WIRE.md")

        // The saved answer, read the way a joining device reads it.
        let answer = try SquadWire.decoder.decode(Enrolled.self, from: Data(saved.enrolled.utf8))
        let credential = try request.accept(answer, invite: try SquadInvite(url: try XCTUnwrap(URL(string: saved.inviteURL)), scheme: "squadz"))
        XCTAssertEqual(credential.secret.hex, saved.memberSecret)
        XCTAssertEqual(credential.linkKey, memberLink)
        XCTAssertTrue(memberLink.accepts(try XCTUnwrap(Data(hex: saved.memberProof)), binding: binding))
        XCTAssertFalse(memberLink.accepts(try XCTUnwrap(Data(hex: saved.memberProof)), binding: bytes(201, 32)), "another session")
        var pinned = credential
        XCTAssertTrue(pinned.apply(try SquadWire.decoder.decode(LeaderKeyChange.self, from: Data(saved.leaderKeyChange.utf8))))
    }
}
