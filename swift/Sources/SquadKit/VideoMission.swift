import Foundation

// Squad video, first cut (docs/VIDEO.md): a member's phone streams its camera to the leader's
// device, and only there. This mission is the part that decides: who is streaming, how many may
// at once, and when a stream ends. The pictures themselves are frames the phone sends on its own
// link to the leader's device, so they are protected exactly as everything else on that link is,
// through a relay included, and nothing but the leader's device can see them.

/// The video add-on to a squad.
public struct VideoMission: Mission {
    public static let id = "squadz.video"
    public static let version = 1
    /// The leader asking someone to stream. The phone still starts only on a tap.
    public static let streamOrder = Order.Kind(rawValue: "squadz.video.stream")
    public static let orderKinds = [streamOrder]

    /// One member's camera, on its way to the leader's device.
    public struct Stream: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var member: MemberID
        public var since: Date
        /// The leader's device is saving this stream. Everyone is told, the streaming phone first.
        public var recording: Bool
        /// How many still pictures the leader's device has kept from it.
        public var stills: Int

        public init(id: UUID, member: MemberID, since: Date, recording: Bool = false, stills: Int = 0) {
            self.id = id
            self.member = member
            self.since = since
            self.recording = recording
            self.stills = stills
        }

        private enum Keys: String, CodingKey { case id, member, since, recording, stills }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            id = try c.decode(UUID.self, forKey: .id)
            member = try c.decode(MemberID.self, forKey: .member)
            since = try c.decode(Date.self, forKey: .since)
            // Absent from a leader that doesn't keep anything.
            recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? false
            stills = try c.decodeIfPresent(Int.self, forKey: .stills) ?? 0
        }
    }

    /// This mission's part of the squad's status: who is streaming, and the leader's limits.
    public struct Status: Codable, Equatable, Sendable {
        public var streams: [Stream]
        /// How many may stream at once.
        public var maxStreams: Int
        /// The bit rate a streaming phone should aim for, in kilobits a second.
        public var kbps: Int
    }

    /// A message about a stream, either way, as JSON.
    public struct Control: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            /// Member → leader: this phone is starting the stream.
            case start
            /// Either way: the stream is over.
            case stop
            /// Leader → member: not now, and why.
            case refused
        }
        public var t: Kind
        public var stream: UUID
        public var why: String?

        public init(_ t: Kind, stream: UUID, why: String? = nil) {
            self.t = t
            self.stream = stream
            self.why = why
        }
    }

    /// One encoded picture, member → leader. Not JSON: a byte of 1, the stream's ID (16 bytes),
    /// the frame's count (4 bytes, big-endian), a byte that is 1 for a key frame, then H.264 in
    /// Annex B form.
    public struct Frame: Equatable, Sendable {
        public var stream: UUID
        public var count: UInt32
        /// A frame that can be shown without any before it. It carries the parameter sets.
        public var isKey: Bool
        public var data: Data

        public init(stream: UUID, count: UInt32, isKey: Bool, data: Data) {
            self.stream = stream
            self.count = count
            self.isKey = isKey
            self.data = data
        }

        static let marker: UInt8 = 1
        static let header = 22

        public var payload: Data {
            var out = Data([Self.marker])
            out += stream.bytes
            out += count.bigEndianBytes
            out.append(isKey ? 1 : 0)
            out += data
            return out
        }

        public init?(payload: Data) {
            let p = Data(payload)
            guard p.count > Self.header, p[0] == Self.marker else { return nil }
            let id = p.subdata(in: 1..<17)
            stream = id.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            count = p.subdata(in: 17..<21).reduce(0) { $0 << 8 | UInt32($1) }
            isKey = p[21] == 1
            data = p.subdata(in: Self.header..<p.count)
        }
    }

    public private(set) var streams: [Stream] = []
    public var maxStreams: Int
    public var kbps: Int

    public init(maxStreams: Int = 1, kbps: Int = 300) {
        self.maxStreams = max(1, maxStreams)
        self.kbps = max(50, kbps)
    }

    // MARK: Messages

    public static func message(_ control: Control) -> SquadMessage.Body {
        // Encoding a small struct of strings doesn't fail.
        .mission(MissionMessage(id: id, version: version, payload: (try? SquadWire.encoder.encode(control)) ?? Data()))
    }

    public static func message(_ frame: Frame) -> SquadMessage.Body {
        .mission(MissionMessage(id: id, version: version, payload: frame.payload))
    }

    /// The control message in a mission message, if it is this mission's and is one.
    public static func control(in message: MissionMessage) -> Control? {
        guard message.id == id, message.version == version, message.payload.first == UInt8(ascii: "{") else { return nil }
        return try? SquadWire.decoder.decode(Control.self, from: message.payload)
    }

    /// The frame in a mission message, if it is this mission's and is one.
    public static func frame(in message: MissionMessage) -> Frame? {
        guard message.id == id, message.version == version else { return nil }
        return Frame(payload: message.payload)
    }

    /// This mission's part of a status, as a device reads it.
    public static func status(in status: SquadStatus) -> Status? {
        status.mission(id, version: version).flatMap { try? SquadWire.decoder.decode(Status.self, from: $0) }
    }

    // MARK: The leader's side

    /// Streams whose phone is still in the squad and linked. A phone that drops or leaves takes
    /// its stream with it.
    public func active(core: CoreView) -> [Stream] {
        streams.filter { core.member($0.member) != nil && core.peer(of: $0.member) != nil }
    }

    /// True if this frame belongs to a stream that member is running now.
    public func accepts(_ frame: Frame, from member: MemberID, core: CoreView) -> Bool {
        active(core: core).contains { $0.id == frame.stream && $0.member == member }
    }

    public mutating func handle(_ payload: Data, from member: MemberID, peer: PeerID, core: CoreView, now: Date) -> MissionStep {
        // Frames go straight to the screen; the app takes them before they get here.
        guard payload.first == UInt8(ascii: "{"), let control = try? SquadWire.decoder.decode(Control.self, from: payload) else { return .none }
        switch control.t {
        case .start:
            streams = active(core: core)
            if streams.contains(where: { $0.id == control.stream && $0.member == member }) { return .none }
            // A phone that starts again replaces its own stream.
            streams.removeAll { $0.member == member }
            guard streams.count < maxStreams else {
                let who = streams.first.flatMap { core.member($0.member)?.name } ?? "Someone"
                return MissionStep([Outgoing(to: peer, Self.message(Control(.refused, stream: control.stream, why: "\(who) is streaming. One at a time.")))])
            }
            streams.append(Stream(id: control.stream, member: member, since: now))
            return .changed()
        case .stop:
            guard streams.contains(where: { $0.id == control.stream && $0.member == member }) else { return .none }
            streams.removeAll { $0.id == control.stream }
            return .changed()
        case .refused:
            return .none   // the leader's word, not a phone's
        }
    }

    /// The leader ends a stream. Run it with `SquadCore.run`.
    public mutating func stop(_ id: UUID, core: CoreView) -> MissionStep {
        guard let stream = streams.first(where: { $0.id == id }) else { return .none }
        streams.removeAll { $0.id == id }
        let told = core.peer(of: stream.member).map { [Outgoing(to: $0, Self.message(Control(.stop, stream: id, why: "The leader stopped the stream.")))] } ?? []
        return .changed(told)
    }

    /// The leader's device starts or stops saving a stream. It is in the status at once, so the
    /// streaming phone and the rest of the squad see it: nothing is kept without that. Run it
    /// with `SquadCore.run`.
    public mutating func setRecording(_ id: UUID, _ on: Bool, core: CoreView) -> MissionStep {
        guard let i = streams.firstIndex(where: { $0.id == id }), streams[i].recording != on else { return .none }
        streams[i].recording = on
        return .changed()
    }

    /// The leader's device kept a still picture from a stream. Counted in the status for the
    /// same reason.
    public mutating func tookStill(_ id: UUID, core: CoreView) -> MissionStep {
        guard let i = streams.firstIndex(where: { $0.id == id }) else { return .none }
        streams[i].stills += 1
        return .changed()
    }

    public func holds(core: CoreView, now: Date) -> Set<Hold> { [] }

    public func status(core: CoreView, now: Date) -> Data? {
        try? SquadWire.encoder.encode(Status(streams: active(core: core), maxStreams: maxStreams, kbps: kbps))
    }
}
