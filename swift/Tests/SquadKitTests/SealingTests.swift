import Foundation
import XCTest
@testable import SquadKit

/// Sealed links (docs/WIRE.md §9): what a relay carries and can't read or change.
final class SealingTests: XCTestCase {
    let key = LinkKey(identity: "m:01", key: Data(repeating: 1, count: 32))
    let carrier = Data(repeating: 2, count: 32)
    let deviceNonce = Data(repeating: 3, count: 16), leaderNonce = Data(repeating: 4, count: 16)

    private func ends(key: LinkKey? = nil, carrier: Data? = nil, device: Data? = nil, leader: Data? = nil) throws -> (device: SealedLink, leader: SealedLink) {
        let d = try XCTUnwrap(SealedLink(key: self.key, side: .device, carrier: self.carrier, device: deviceNonce, leader: leaderNonce))
        let l = try XCTUnwrap(SealedLink(key: key ?? self.key, side: .leader, carrier: carrier ?? self.carrier,
                                         device: device ?? deviceNonce, leader: leader ?? leaderNonce))
        return (d, l)
    }

    func testFramesCrossBothWaysInOrder() throws {
        var (device, leader) = try ends()
        for text in ["hello", "", "position", String(repeating: "x", count: 70_000)] {
            let sealed = try device.seal(Data(text.utf8))
            XCTAssertEqual(sealed.count, text.utf8.count + SealedLink.overhead)
            XCTAssertEqual(try leader.open(sealed), Data(text.utf8))
            XCTAssertEqual(try device.open(try leader.seal(Data(text.utf8))), Data(text.utf8))
        }
    }

    func testTheSameWordsNeverSealTheSameWay() throws {
        var (device, leader) = try ends()
        let words = Data("check fire".utf8)
        let sealed = [try device.seal(words), try device.seal(words), try leader.seal(words)]
        XCTAssertEqual(Set(sealed).count, 3)
        XCTAssertFalse(sealed.contains { $0.range(of: words) != nil })
    }

    func testAFrameThatWasChangedDroppedRepeatedOrTurnedRoundDoesntOpen() throws {
        var (device, leader) = try ends()
        let first = try device.seal(Data("one".utf8)), second = try device.seal(Data("two".utf8))

        var changed = first
        changed[0] ^= 1
        XCTAssertThrowsError(try leader.open(changed))
        XCTAssertThrowsError(try leader.open(second), "the first frame was dropped")
        XCTAssertThrowsError(try leader.open(Data()))
        XCTAssertEqual(try leader.open(first), Data("one".utf8))
        XCTAssertThrowsError(try leader.open(first), "the same frame again")
        XCTAssertEqual(try leader.open(second), Data("two".utf8), "a frame that didn't open doesn't use up its place")

        // What the leader's device sent, sent back to it.
        let fromLeader = try leader.seal(Data("three".utf8))
        var (_, other) = try ends()
        XCTAssertThrowsError(try other.open(fromLeader))
        XCTAssertThrowsError(try leader.open(fromLeader))
    }

    func testAnotherKeyOrAnotherNonceMakesAnotherLink() throws {
        let sealed: () throws -> Data = { var (device, _) = try self.ends(); return try device.seal(Data("hello".utf8)) }
        var otherKey = try ends(key: LinkKey(identity: "m:01", key: Data(repeating: 9, count: 32))).leader
        XCTAssertThrowsError(try otherKey.open(try sealed()))
        // A session recorded earlier doesn't play back: the leader's nonce is new each time.
        var later = try ends(leader: Data(repeating: 5, count: 16)).leader
        XCTAssertThrowsError(try later.open(try sealed()))
        var otherDevice = try ends(device: Data(repeating: 5, count: 16)).leader
        XCTAssertThrowsError(try otherDevice.open(try sealed()))
        var otherCarrier = try ends(carrier: Data(repeating: 5, count: 32)).leader
        XCTAssertThrowsError(try otherCarrier.open(try sealed()))

        XCTAssertNil(SealedLink(key: key, side: .device, carrier: carrier, device: Data(count: 8), leader: leaderNonce))
        XCTAssertNil(SealedLink(key: key, side: .device, carrier: carrier, device: deviceNonce, leader: Data()))
    }
}
