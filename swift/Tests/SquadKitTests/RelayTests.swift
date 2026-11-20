import Foundation
import XCTest
import SquadKit

/// What an invite and a credential say about a relay (docs/RELAY.md).
final class RelayTests: XCTestCase {
    func testAnInviteCarriesItsRelayThroughItsLink() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        var invite = host.openJoining(now: Date(timeIntervalSince1970: 1_800_000_000))
        let pin = Data((0..<32).map { UInt8($0) })

        invite.relay = RelayAddress(text: "wss://relay.example:8443", pin: pin.base64URL)
        let url = invite.url(scheme: "squadz")
        XCTAssertTrue(url.absoluteString.contains("relay=wss://relay.example:8443"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("relay_pin=AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"), url.absoluteString)
        let read = try SquadInvite(url: url, scheme: "squadz")
        XCTAssertEqual(read, invite)
        XCTAssertEqual(read.relay?.pin, pin)

        // Without a pin, and without a relay at all.
        invite.relay = RelayAddress(text: "relay.example")
        XCTAssertEqual(try SquadInvite(url: invite.url(scheme: "squadz"), scheme: "squadz").relay?.text, "wss://relay.example")
        invite.relay = nil
        XCTAssertNil(try SquadInvite(url: invite.url(scheme: "squadz"), scheme: "squadz").relay)
    }

    func testAnInviteWithABadRelayIsRefusedWhole() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let base = host.openJoining(now: Date(timeIntervalSince1970: 1_800_000_000)).url(scheme: "squadz").absoluteString
        let pin = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        for extra in [
            "&relay=ws://relay.example",                    // in the clear
            "&relay=https://relay.example",
            "&relay=wss://relay.example/elsewhere",         // a path of someone's choosing
            "&relay=wss://relay.example?x=1",
            "&relay=wss://user:pw@relay.example",
            "&relay=wss://",
            "&relay_pin=\(pin)",                            // a pin for no relay
            "&relay=wss://relay.example&relay_pin=AAEC",    // a pin of the wrong size
            "&relay=wss://relay.example&relay=wss://other.example",
        ] {
            XCTAssertThrowsError(try SquadInvite(url: try XCTUnwrap(URL(string: base + extra)), scheme: "squadz"), extra) {
                XCTAssertEqual($0 as? SquadInvite.ParseError, .malformed, extra)
            }
        }
    }

    func testARelayAddressAsTyped() {
        XCTAssertEqual(RelayAddress(text: " Relay.Example:8443 ")?.text, "wss://relay.example:8443")
        XCTAssertEqual(RelayAddress(text: "wss://203.0.113.5/")?.text, "wss://203.0.113.5")
        XCTAssertNil(RelayAddress(text: ""))
        XCTAssertNil(RelayAddress(text: "http://relay.example"))
        XCTAssertNil(RelayAddress(text: "relay.example", pin: "not a pin"))
        XCTAssertNil(RelayAddress(text: "relay.example", pin: "")?.pin)
    }

    /// A fixed vector: any other client must derive the same key.
    func testTheRelayKeyComesFromTheInvitesSecretAndTheRelayHoldsOnlyItsHash() throws {
        let enrol = Data((0..<16).map { UInt8($0) })
        XCTAssertEqual(SquadInvite.relayKey(enrol: enrol).hex, "7352fbf0b3fa6adb421747a0ebd76357698a2f76d1342aecf86f1c98afd191d6")

        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = host.openJoining(now: now)
        let known = host.relayInvites(now: now)
        XCTAssertEqual(known.count, 1)
        XCTAssertEqual(known.first?.expires, invite.expires)
        XCTAssertNotEqual(known.first?.hash, invite.relayKey)
        XCTAssertNotEqual(invite.relayKey, invite.enrol)
        XCTAssertNotEqual(invite.relayKey, invite.linkKey.key)

        XCTAssertTrue(host.relayInvites(now: invite.expires).isEmpty, "an expired invite")
        host.closeJoining()
        XCTAssertTrue(host.relayInvites(now: now).isEmpty, "joining closed")
    }

    func testACredentialKeepsItsTicketAndOneSavedBeforeRelaysStillReads() throws {
        var host = SquadCore(squad: Squad(name: "Red"), mission: NoMission())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invite = host.openJoining(now: now)
        let peer = PeerID("phone")
        host.linkOpened(peer, identity: invite.linkKey.identity)
        let request = EnrolmentRequest(name: "Ana", device: UUID())
        let out = host.handle(SquadMessage(seq: 1, body: .hello(request.hello)), from: peer, now: now)
        guard case let .enrolled(answer)? = out.first?.body else { return XCTFail("not enrolled") }
        var credential = try request.accept(answer, invite: invite)

        let before = try JSONEncoder().encode(credential)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("relay"))
        XCTAssertNil(try JSONDecoder().decode(MemberCredential.self, from: before).relay)

        credential.relay = RelayTicket(address: RelayAddress(text: "relay.example")!, device: "0a1b", token: Data(repeating: 9, count: 32))
        XCTAssertEqual(try JSONDecoder().decode(MemberCredential.self, from: try JSONEncoder().encode(credential)), credential)
    }
}
