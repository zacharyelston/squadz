import Foundation
import XCTest
@testable import SquadKit

/// Squad video's deciding part (docs/VIDEO.md): who is streaming, one at a time, and how it ends.
final class VideoMissionTests: XCTestCase {
    private func control(_ kind: VideoMission.Control.Kind, _ id: UUID) -> SquadMessage.Body {
        VideoMission.message(VideoMission.Control(kind, stream: id))
    }

    private func streams(_ y: Yard<VideoMission>, _ who: String) -> [VideoMission.Stream]? {
        y.lastStatus(who).flatMap(VideoMission.status(in:))?.streams
    }

    private func told(_ y: Yard<VideoMission>, _ who: String, _ kind: VideoMission.Control.Kind, _ id: UUID) -> Bool {
        y.has(who) {
            if case let .mission(m) = $0, let c = VideoMission.control(in: m) { return c.t == kind && c.stream == id }
            return false
        }
    }

    func testOnePhoneStreamsAtATimeAndEveryoneSeesWho() throws {
        let y = Yard(mission: VideoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        y.join("Ben")
        XCTAssertEqual(streams(y, "Ana"), [])
        XCTAssertEqual(y.lastStatus("Ana").flatMap(VideoMission.status(in:))?.kbps, 300)

        let first = UUID()
        y.send("Ana", control(.start, first))
        XCTAssertEqual(streams(y, "Ben")?.map(\.member), [ana], "Ben can see that Ana is streaming")
        XCTAssertEqual(streams(y, "Ben")?.first?.id, first)
        // Saying it twice changes nothing.
        y.send("Ana", control(.start, first))
        XCTAssertEqual(y.host.mission.streams.count, 1)

        // Ben is turned down while she is, and told why.
        let second = UUID()
        y.send("Ben", control(.start, second))
        XCTAssertTrue(told(y, "Ben", .refused, second))
        XCTAssertEqual(streams(y, "Ana")?.map(\.id), [first])

        // He can't end hers. She can.
        y.send("Ben", control(.stop, first))
        XCTAssertEqual(streams(y, "Ana")?.map(\.id), [first])
        y.send("Ana", control(.stop, first))
        XCTAssertEqual(streams(y, "Ben"), [])
        y.send("Ben", control(.start, second))
        XCTAssertEqual(streams(y, "Ana")?.map(\.id), [second])
    }

    func testTheLeaderStopsAStreamAndADroppedPhoneTakesItsStreamWithIt() throws {
        let y = Yard(mission: VideoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        y.join("Ben")
        let first = UUID()
        y.send("Ana", control(.start, first))

        y.command { core, now in core.run(now) { mission, view in mission.stop(first, core: view) } }
        XCTAssertTrue(told(y, "Ana", .stop, first))
        XCTAssertEqual(streams(y, "Ben"), [])
        // A phone can't refuse anyone, and stopping what isn't running does nothing.
        y.send("Ben", control(.refused, first))
        XCTAssertTrue(y.host.run(y.now) { mission, view in mission.stop(first, core: view) }.isEmpty)

        // Her link goes without a word: her stream is not listed any more, and Ben may start.
        let again = UUID()
        y.send("Ana", control(.start, again))
        XCTAssertEqual(streams(y, "Ben")?.map(\.member), [ana])
        y.host.peerClosed(y.peer("Ana"))
        XCTAssertEqual(VideoMission.status(in: y.host.status(now: y.now))?.streams, [])
        let bens = UUID()
        y.send("Ben", control(.start, bens))
        XCTAssertEqual(y.host.mission.streams.map(\.id), [bens])
    }

    func testEveryoneIsToldWhenTheLeaderKeepsAnything() throws {
        let y = Yard(mission: VideoMission())
        y.join("Ana")
        y.join("Ben")
        let id = UUID()
        y.send("Ana", control(.start, id))
        XCTAssertEqual(streams(y, "Ana")?.first?.recording, false)
        XCTAssertEqual(streams(y, "Ana")?.first?.stills, 0)

        // Recording is in the status the moment it starts, for the streaming phone and for everyone else.
        y.command { core, now in core.run(now) { mission, view in mission.setRecording(id, true, core: view) } }
        XCTAssertEqual(streams(y, "Ana")?.first?.recording, true)
        XCTAssertEqual(streams(y, "Ben")?.first?.recording, true)
        // Saying it again sends nothing; a still is counted and told.
        XCTAssertTrue(y.host.run(y.now) { mission, view in mission.setRecording(id, true, core: view) }.isEmpty)
        y.command { core, now in core.run(now) { mission, view in mission.tookStill(id, core: view) } }
        XCTAssertEqual(streams(y, "Ben")?.first?.stills, 1)
        y.command { core, now in core.run(now) { mission, view in mission.setRecording(id, false, core: view) } }
        XCTAssertEqual(streams(y, "Ana")?.first?.recording, false)

        // A stream that isn't running can't be recorded, and a new stream starts unrecorded.
        XCTAssertTrue(y.host.run(y.now) { mission, view in mission.setRecording(UUID(), true, core: view) }.isEmpty)
        y.command { core, now in core.run(now) { mission, view in mission.setRecording(id, true, core: view) } }
        y.send("Ana", control(.stop, id))
        let next = UUID()
        y.send("Ana", control(.start, next))
        XCTAssertEqual(streams(y, "Ben")?.first?.recording, false)

        // A status from a leader that keeps nothing still reads.
        let old = Data(#"{"streams":[{"id":"00000000-0000-4000-8000-000000000001","member":"00000000-0000-4000-8000-000000000002","since":1800000000000}],"maxStreams":1,"kbps":300}"#.utf8)
        let read = try SquadWire.decoder.decode(VideoMission.Status.self, from: old)
        XCTAssertEqual(read.streams.first?.recording, false)
    }

    func testFramesKeepTheirShapeAndOnlyTheStreamersCount() throws {
        let id = UUID()
        let frame = VideoMission.Frame(stream: id, count: 70_000, isKey: true, data: Data([0, 0, 0, 1, 0x67, 9, 8, 7]))
        guard case let .mission(message) = VideoMission.message(frame) else { return XCTFail() }
        XCTAssertEqual(message.payload.count, 22 + 8)
        XCTAssertEqual(VideoMission.frame(in: message), frame)
        XCTAssertNil(VideoMission.control(in: message), "a frame is not a control message")
        XCTAssertNil(VideoMission.Frame(payload: Data([1, 2, 3])))
        XCTAssertNil(VideoMission.Frame(payload: Data(#"{"t":"start"}"#.utf8) + Data(count: 30)))
        // Through the wire and back, as it travels.
        let wire = try SquadWire.encode(SquadMessage(seq: 1, body: VideoMission.message(frame)))
        var reader = SquadWire.FrameReader()
        guard case let .mission(back)? = try reader.append(wire).first?.body else { return XCTFail() }
        XCTAssertEqual(VideoMission.frame(in: back), frame)

        let y = Yard(mission: VideoMission())
        let ana = try XCTUnwrap(y.join("Ana"))
        let ben = try XCTUnwrap(y.join("Ben"))
        XCTAssertFalse(y.host.mission.accepts(frame, from: ana, core: y.host.view), "nobody is streaming yet")
        y.send("Ana", control(.start, id))
        XCTAssertTrue(y.host.mission.accepts(frame, from: ana, core: y.host.view))
        XCTAssertFalse(y.host.mission.accepts(frame, from: ben, core: y.host.view), "her stream, not his")
        // A frame handed to the core changes nothing: frames are for the screen.
        let before = y.host.revision
        y.send("Ana", VideoMission.message(frame))
        XCTAssertEqual(y.host.revision, before)
    }

    func testADeviceWithoutVideoIsStillAFullMember() throws {
        // A squad with no mission ignores video's messages and refuses nobody for sending them.
        let y = Yard(mission: NoMission())
        y.join("Ana")
        y.send("Ana", control(.start, UUID()))
        XCTAssertFalse(y.has("Ana") { if case .refused = $0 { return true }; return false })
        XCTAssertEqual(y.host.squad.members.count, 1)
    }
}
