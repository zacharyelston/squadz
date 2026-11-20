import CoreGeo
import Foundation
import SquadKit

// The mission log: what happened in one squad, in time order, kept on the leader's device for
// review afterwards. Positions, orders and their answers, notes, who joined and left, streams,
// and the clips and stills kept from them. One folder per squad:
//
//   missions/<squad id>/mission.json   what the squad was and when
//   missions/<squad id>/log.jsonl      one entry per line, oldest first
//   missions/<squad id>/media/         the clips and stills entries point to
//
// Nothing here leaves the device unless the leader exports it.

/// One squad's log, as listed.
struct MissionInfo: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var started: Date
    var ended: Date?
}

/// One thing that happened.
struct LogEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case squadStarted, squadEnded
        case joined, left, removed
        case position
        case order, orderAnswer, orderCancelled
        case note
        case zoneArrival, zoneDeparture
        case streamStarted, streamStopped
        /// A recording of a stream, in `file`.
        case clip
        /// A still picture from a stream, in `file`.
        case still
    }

    var id = UUID()
    var time: Date
    var kind: Kind
    /// Who it is about.
    var member: MemberID?
    /// Their name at the time, so the log reads on its own.
    var name: String?
    var at: GeoPoint?
    var accuracy: Double?
    var heading: Double?
    var text: String?
    /// The order or stream this belongs to.
    var ref: UUID?
    /// A file in the mission's `media` folder.
    var file: String?
    /// How long a clip runs.
    var seconds: Double?

    var isMedia: Bool { kind == .clip || kind == .still }
}

/// Reads and writes mission logs under one folder.
final class MissionLogStore {
    let root: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    init(root: URL) {
        self.root = root
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString) }
    private func infoFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("mission.json") }
    private func logFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("log.jsonl") }
    func mediaFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("media") }
    func media(_ id: UUID, _ file: String) -> URL { mediaFolder(id).appendingPathComponent(file) }

    /// Every mission on this device, newest first.
    func missions() -> [MissionInfo] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url in
            (try? Data(contentsOf: url.appendingPathComponent("mission.json"))).flatMap { try? decoder.decode(MissionInfo.self, from: $0) }
        }.sorted { $0.started > $1.started }
    }

    func info(_ id: UUID) -> MissionInfo? {
        (try? Data(contentsOf: infoFile(id))).flatMap { try? decoder.decode(MissionInfo.self, from: $0) }
    }

    /// Starts a mission's log, or picks one up where it left off. True if it is new.
    @discardableResult
    func begin(_ id: UUID, name: String, now: Date) -> Bool {
        try? FileManager.default.createDirectory(at: mediaFolder(id), withIntermediateDirectories: true)
        if var known = info(id) {
            if known.name != name || known.ended != nil {
                known.name = name
                known.ended = nil
                write(known)
            }
            return false
        }
        write(MissionInfo(id: id, name: name, started: now))
        return true
    }

    func end(_ id: UUID, now: Date) {
        guard var known = info(id) else { return }
        known.ended = now
        write(known)
    }

    private func write(_ info: MissionInfo) {
        guard let data = try? encoder.encode(info) else { return }
        try? data.write(to: infoFile(info.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Adds to the end of a mission's log.
    func append(_ entries: [LogEntry], to id: UUID) {
        guard !entries.isEmpty else { return }
        var lines = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            lines += line
            lines.append(0x0A)
        }
        let file = logFile(id)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lines)
        } else {
            try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            try? lines.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// A mission's log, oldest first. A line that doesn't read is skipped, not fatal.
    func entries(of id: UUID) -> [LogEntry] {
        guard let data = try? Data(contentsOf: logFile(id)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(LogEntry.self, from: Data($0)) }
    }

    /// A name and place for a new clip or still.
    func newMedia(in id: UUID, kind: LogEntry.Kind, now: Date) -> (name: String, url: URL) {
        try? FileManager.default.createDirectory(at: mediaFolder(id), withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970 * 1000)
        let name = "\(kind.rawValue)-\(stamp).\(kind == .clip ? "mp4" : "jpg")"
        return (name, media(id, name))
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    /// The whole mission (its log and its media) as one zip file to hand to someone, in the
    /// temporary folder.
    func export(_ id: UUID) -> URL? {
        var made: URL?
        var problem: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder(id), options: .forUploading, error: &problem) { zipped in
            let name = (info(id)?.name ?? "mission").replacingOccurrences(of: "/", with: "-")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) mission log.zip")
            try? FileManager.default.removeItem(at: out)
            if (try? FileManager.default.copyItem(at: zipped, to: out)) != nil { made = out }
        }
        return made
    }
}

/// Works out what is new in a squad's state since it last looked, as log entries. The leader's
/// app calls it after anything changes, so nothing has to remember to log.
struct MissionLogger {
    private var positions: [MemberID: Date] = [:]
    private var members: [MemberID: String] = [:]
    private var orders: Set<UUID> = []
    private var answers: [UUID: [MemberID: OrderAck.Response]] = [:]
    private var cancelled: Set<UUID> = []
    private var notes: Set<UUID> = []
    private var notices: Set<UUID> = []
    private var streams: [UUID: MemberID] = [:]
    private var zoneEvents: Set<UUID> = []

    /// - Parameter resuming: the leader's app came back to a squad it was already leading, so the
    ///   people already in it are not joining now.
    init<M: Mission>(resuming core: SquadCore<M>?) {
        if let core {
            members = Dictionary(core.squad.members.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            zoneEvents = Set(core.zoneEvents.map(\.id))
        }
    }

    mutating func changes<M: Mission>(in core: SquadCore<M>, streams live: [VideoMission.Stream], now: Date) -> [LogEntry] {
        var out: [LogEntry] = []
        func name(_ id: MemberID?) -> String? { id.flatMap { id in core.squad.members.first { $0.id == id }?.name ?? members[id] } }

        for m in core.squad.members where members[m.id] == nil {
            out.append(LogEntry(time: now, kind: .joined, member: m.id, name: m.name))
        }
        for n in core.notices where !notices.contains(n.id) {
            notices.insert(n.id)
            out.append(LogEntry(time: n.time, kind: n.kind == .removed ? .removed : .left, member: n.member, name: name(n.member), text: n.text))
        }
        members.merge(core.squad.members.map { ($0.id, $0.name) }) { _, new in new }

        for (member, p) in core.positions.sorted(by: { $0.value.time < $1.value.time }) where positions[member] != p.time {
            positions[member] = p.time
            out.append(LogEntry(time: p.time, kind: .position, member: member, name: name(member), at: p.at, accuracy: p.accuracy, heading: p.heading))
        }

        for o in core.orders where !orders.contains(o.id) {
            orders.insert(o.id)
            let who = o.to.map { $0.compactMap { name($0) }.joined(separator: ", ") } ?? "the whole squad"
            let what = [o.kind.appTitle ?? o.kind.rawValue, o.text].filter { !$0.isEmpty }.joined(separator: ": ")
            out.append(LogEntry(time: o.time, kind: .order, at: o.at, text: "\(what), to \(who)", ref: o.id))
        }
        for (order, given) in core.acks {
            for (member, answer) in given where answers[order]?[member] != answer {
                answers[order, default: [:]][member] = answer
                out.append(LogEntry(time: now, kind: .orderAnswer, member: member, name: name(member), text: answer.title, ref: order))
            }
        }
        for id in core.cancelled where !cancelled.contains(id) {
            cancelled.insert(id)
            out.append(LogEntry(time: now, kind: .orderCancelled, ref: id))
        }

        for n in core.notes where !notes.contains(n.id) {
            notes.insert(n.id)
            out.append(LogEntry(time: n.time, kind: .note, name: n.author, at: n.at, accuracy: n.accuracy, text: n.text))
        }

        for event in core.zoneEvents where !zoneEvents.contains(event.id) {
            zoneEvents.insert(event.id)
            out.append(LogEntry(id: event.id, time: event.time, kind: event.kind == .arrived ? .zoneArrival : .zoneDeparture,
                                member: event.member, name: event.memberName, at: core.positions[event.member]?.at,
                                text: event.text, ref: event.zone))
        }
        zoneEvents.formIntersection(Set(core.zoneEvents.map(\.id)))

        let now_ = Dictionary(live.map { ($0.id, $0.member) }, uniquingKeysWith: { a, _ in a })
        for s in live where streams[s.id] == nil {
            out.append(LogEntry(time: s.since, kind: .streamStarted, member: s.member, name: name(s.member), at: core.positions[s.member]?.at, ref: s.id))
        }
        for (id, member) in streams where now_[id] == nil {
            out.append(LogEntry(time: now, kind: .streamStopped, member: member, name: name(member), ref: id))
        }
        streams = now_
        return out
    }
}
