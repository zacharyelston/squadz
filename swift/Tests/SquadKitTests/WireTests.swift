import Foundation
import XCTest
@testable import SquadKit

/// The wire format (docs/WIRE.md), pinned by testdata/wire/messages.json. Every implementation,
/// in any language, must read and write those exact messages.
final class WireTests: XCTestCase {
    static let vectors = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("testdata/wire/messages.json")

    struct Vector: Codable, Equatable {
        var type: String
        /// The frame's JSON, exactly as sent (after the 4-byte length).
        var json: String
    }

    func testMessagesMatchTheSharedVectors() throws {
        let made = try Samples.all().enumerated().map { i, body -> Vector in
            let message = SquadMessage(seq: i + 1, body: body)
            let frame = try SquadWire.encode(message)
            return Vector(type: message.type, json: String(decoding: frame.dropFirst(4), as: UTF8.self))
        }
        if ProcessInfo.processInfo.environment["UPDATE_VECTORS"] == "1" {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try e.encode(made).write(to: Self.vectors)
        }
        let saved = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: Self.vectors))
        XCTAssertEqual(made, saved, "the wire changed: bump SquadProtocol.version, then rerun with UPDATE_VECTORS=1")

        // And back: each saved message decodes to the sample it came from.
        for (i, v) in saved.enumerated() {
            let decoded = try SquadWire.decoder.decode(SquadMessage.self, from: Data(v.json.utf8))
            XCTAssertEqual(decoded, SquadMessage(seq: i + 1, body: Samples.all()[i]), v.type)
        }
        XCTAssertEqual(Set(saved.map(\.type)).count, 23, "every message type has a vector")
    }

    func testFramesSplitAndJoinedAcrossReads() throws {
        let bodies = Samples.all()
        var stream = Data()
        for (i, b) in bodies.enumerated() { stream.append(try SquadWire.encode(SquadMessage(seq: i, body: b))) }
        var reader = SquadWire.FrameReader()
        var got: [SquadMessage] = []
        var i = stream.startIndex
        var chunk = 1
        while i < stream.endIndex {
            let end = min(stream.endIndex, i + chunk)
            got += try reader.append(stream[i..<end])
            i = end
            chunk = chunk % 97 + 7
        }
        XCTAssertEqual(got.map(\.body), bodies)
    }

    func testOversizeGarbageAndUnknownFramesAreRefused() throws {
        var reader = SquadWire.FrameReader()
        var huge = UInt32(SquadWire.maxFrameBytes + 1).bigEndian
        XCTAssertThrowsError(try reader.append(Data(bytes: &huge, count: 4)))
        func frame(_ text: String) -> Data {
            var n = UInt32(text.utf8.count).bigEndian
            return Data(bytes: &n, count: 4) + Data(text.utf8)
        }
        XCTAssertThrowsError(try reader.append(frame("hello")))
        reader = SquadWire.FrameReader()
        XCTAssertThrowsError(try reader.append(frame(#"{"v":7,"seq":1,"type":"teleport","body":{}}"#)), "an unknown type")
        reader = SquadWire.FrameReader()
        XCTAssertThrowsError(try reader.append(frame(#"{"v":7,"seq":1,"type":"hello"}"#)), "a body that's missing")
        reader = SquadWire.FrameReader()
        XCTAssertEqual(try reader.append(frame(#"{"v":7,"seq":1,"type":"bye","extra":1}"#)).map(\.body), [.bye], "unknown fields are ignored")
    }

    /// The core has no message that can carry firing data: a mission that has any keeps it on the
    /// leader's device.
    func testNoCoreMessageCarriesFiringData() throws {
        let forbidden = ["charge", "elevation", "aimoffset", "timeofflight", "solution", "cleared", "velocity", "apex"]
        for body in Samples.all() {
            let json = String(decoding: try SquadWire.encode(SquadMessage(seq: 1, body: body)).dropFirst(4), as: UTF8.self).lowercased()
            for word in forbidden { XCTAssertFalse(json.contains("\"\(word)"), "\(body) carries \(word)") }
        }
    }

    func testJoinCodes() {
        let c = JoinCode.make()
        XCTAssertEqual(c.count, 6)
        XCTAssertTrue(c.allSatisfy { JoinCode.alphabet.contains($0) })
        XCTAssertEqual(JoinCode.normalized("abc-23 4"), "ABC234")
    }
}
