import CoreGeo
import Foundation
import Network
import Observation
import SquadKit
import SquadLink

/// How a member's device is linked to the leader's, as the leader's device sees it.
enum MemberLink: Equatable {
    case direct
    case relay
    case away
}

/// A member and where they were last seen, for the map and the list.
struct Located: Identifiable, Equatable {
    var member: Member
    var position: MemberPosition?
    var isMe: Bool
    var isLeader: Bool
    /// Known only on the leader's device, and not for the leader.
    var link: MemberLink? = nil
    /// When they joined. Known only on the leader's device.
    var joined: Date? = nil
    var id: MemberID { member.id }

    /// A position older than this is shown dimmed.
    static let staleAfter: TimeInterval = 120

    func age(now: Date) -> TimeInterval? { position.map { max(0, now.timeIntervalSince($0.time)) } }
    func isStale(now: Date) -> Bool { age(now: now).map { $0 > Self.staleAfter } ?? true }
}

/// What the leader's device saves between launches. No secrets: its keys are in the Keychain.
struct LeaderSaved: Codable, Equatable {
    var squad: Squad
    var me: MemberID
    var credentials: [CredentialRecord]
    var epoch: Int
    var keyChanges: [LeaderKeyChange]
    var revision: Int
    /// The relay this squad was started with, if any.
    var relay: RelayAddress?
    var zones: [SquadZone]? = nil
    var zoneEvents: [ZoneEvent]? = nil
}

/// The whole app: this phone either leads one squad, is a member of one, or is in none.
///
/// A leader's phone *is* the squad: it holds the roster and everyone's positions and the others
/// connect to it directly, over Wi-Fi or a mesh. There is no server. A squad started with a relay
/// can also be reached over the internet: the relay passes the same links along and decides nothing.
@MainActor
@Observable
final class AppModel {
    enum Role: Equatable { case none, leader, member }

    private(set) var role: Role = .none
    private(set) var squad: Squad?
    private(set) var me: MemberID?
    private(set) var leaderID: MemberID?
    private(set) var positions: [MemberID: MemberPosition] = [:]
    /// Why the squad isn't up to date, for a banner.
    private(set) var linkProblem: String?
    /// An invite that was scanned or opened and is waiting for a yes.
    var offered: SquadInvite?
    private(set) var joining = false
    var alert: String?
    /// The leader's open invite, to show as a QR code.
    private(set) var invite: SquadInvite?
    /// How the relay is doing, for a line under the title. Nil for a squad without one.
    private(set) var relayNote: String?
    /// The latest thing the squad was told, like "Ana left the squad." Shown for a short while.
    private(set) var notice: Notice?

    /// On the leader's device: the orders it sent, newest first. On a member's phone: the orders
    /// that are for it, newest first.
    private(set) var orders: [Order] = []
    /// On the leader's device: each recipient's latest answer to each order.
    private(set) var answers: [UUID: [MemberID: OrderAck.Response]] = [:]
    /// The squad's field notes, oldest first: a chat everyone in the squad reads and writes.
    private(set) var notes: [FieldNote] = []
    /// How many of them this device has shown.
    private(set) var notesRead = 0
    var unreadNotes: Int { max(0, notes.count - notesRead) }

    // MARK: Video (docs/VIDEO.md)

    /// Who is streaming their camera to the leader's device, as the leader's device says.
    private(set) var streams: [VideoMission.Stream] = []
    /// The bit rate the leader asks streaming phones to keep to.
    private(set) var videoKbps = 300
    /// On a member's phone: the stream it is sending. Nil when it isn't.
    private(set) var myStream: UUID?
    private var streamer: VideoStreamer?
    /// On the leader's device: where the pictures are drawn.
    let display = H264Display()
    /// Where a phone's pictures come from. Tests and the simulator give a made-up pattern.
    var videoSource: (@MainActor () -> FrameSource)?

    var isStreaming: Bool { myStream != nil }

    /// What the streaming phone's own bar says: that it is streaming, and anything being kept.
    var streamingNote: String {
        guard let mine = streams.first(where: { $0.id == myStream }) else { return "You are streaming to the leader" }
        var note = "You are streaming to the leader"
        if mine.recording { note += ", and being recorded" }
        if mine.stills > 0 { note += " · \(mine.stills) \(mine.stills == 1 ? "still" : "stills") kept" }
        return note
    }

    func name(of member: MemberID) -> String {
        squad?.members.first { $0.id == member }?.name ?? "Someone"
    }

    /// A member starts streaming this phone's camera to the leader's device. Only ever from a
    /// tap on this phone.
    func startStreaming() {
        guard role == .member, myStream == nil else { return }
        guard linkProblem == nil else {
            alert = "This phone isn't linked to the squad right now."
            return
        }
        let id = UUID()
        let made = videoSource?() ?? Self.defaultSource()
        let streamer = VideoStreamer(stream: id, source: made, kbps: videoKbps) { [weak self] frame in
            guard let self, self.myStream == frame.stream else { return }
            self.client?.send(VideoMission.message(frame))
        }
        myStream = id
        self.streamer = streamer
        client?.send(VideoMission.message(VideoMission.Control(.start, stream: id)))
        Task { [weak self] in
            if await streamer.start() == false {
                self?.endStream(tellLeader: true)
                self?.alert = "Squadz couldn't use the camera. Allow it in Settings, then try again."
            }
        }
    }

    func stopStreaming() {
        endStream(tellLeader: true)
    }

    private func endStream(tellLeader: Bool) {
        guard let id = myStream else { return }
        streamer?.stop()
        streamer = nil
        myStream = nil
        if tellLeader { client?.send(VideoMission.message(VideoMission.Control(.stop, stream: id))) }
    }

    /// The leader ends someone's stream.
    func stopStream(_ id: UUID) {
        guard role == .leader else { return }
        updateLeader { $0.run(.now) { mission, view in mission.stop(id, core: view) } }
    }

    /// On the leader's device: a frame from a phone. Shown only if that phone is the one
    /// streaming, and kept only while the leader is recording.
    private func show(_ frame: VideoMission.Frame, from peer: PeerID) {
        guard let core, let member = core.peers[peer], core.mission.accepts(frame, from: member, core: core.view) else { return }
        guard let sample = display.show(frame.data, isKey: frame.isKey) else { return }
        if let recording, recording.stream == frame.stream { recording.recorder.append(sample, isKey: frame.isKey) }
    }

    // MARK: The mission log (MissionLog.swift)

    /// Every squad this device has led, as logs on this device.
    let logs: MissionLogStore
    private var logger = MissionLogger(resuming: Optional<SquadCore<VideoMission>>.none)
    /// Goes up whenever something is added to a log, so a screen showing one reads it again.
    private(set) var logChanges = 0
    /// The log of the squad this device is leading now.
    var missionID: UUID? { role == .leader ? squad?.id.raw : nil }

    private func log(_ entries: [LogEntry]) {
        guard let id = missionID, !entries.isEmpty else { return }
        logs.append(entries, to: id)
        logChanges += 1
    }

    private struct Recording {
        /// The squad whose log the clip goes in, kept here because the squad may be over by the time the file is closed.
        var mission: UUID
        var stream: UUID
        var member: MemberID
        var at: GeoPoint?
        var file: String
        var recorder: StreamRecorder
    }

    private var recording: Recording?
    var isRecording: Bool { recording != nil }
    /// The last thing kept, to say so on screen for a moment.
    private(set) var captureNote: String?

    /// The leader starts keeping the stream on screen. The squad's status says so at once.
    func startRecording() {
        guard role == .leader, recording == nil, let stream = streams.first, let id = missionID else { return }
        let media = logs.newMedia(in: id, kind: .clip, now: .now)
        recording = Recording(mission: id, stream: stream.id, member: stream.member, at: positions[stream.member]?.at, file: media.name,
                              recorder: StreamRecorder(url: media.url))
        updateLeader { $0.run(.now) { mission, view in mission.setRecording(stream.id, true, core: view) } }
    }

    func stopRecording() {
        endRecording(tellSquad: true)
    }

    /// Closes the clip and puts it in the mission's log.
    private func endRecording(tellSquad: Bool) {
        guard let done = recording else { return }
        recording = nil
        if tellSquad { updateLeader { $0.run(.now) { mission, view in mission.setRecording(done.stream, false, core: view) } } }
        let name = name(of: done.member)
        Task { [weak self] in
            guard let seconds = await done.recorder.finish() else { return }
            guard let self else { return }
            self.logs.append([LogEntry(time: done.recorder.began, kind: .clip, member: done.member, name: name, at: done.at,
                                       ref: done.stream, file: done.file, seconds: seconds)], to: done.mission)
            self.logChanges += 1
            self.say("Clip saved to the mission log.")
        }
    }

    /// The leader keeps the picture on screen now as a still. The squad's status counts it.
    @discardableResult
    func snap() -> Bool {
        guard role == .leader, let stream = streams.first, let id = missionID, let jpeg = display.still() else { return false }
        let media = logs.newMedia(in: id, kind: .still, now: .now)
        guard (try? jpeg.write(to: media.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return false }
        log([LogEntry(time: .now, kind: .still, member: stream.member, name: name(of: stream.member), at: positions[stream.member]?.at,
                      ref: stream.id, file: media.name)])
        updateLeader { $0.run(.now) { mission, view in mission.tookStill(stream.id, core: view) } }
        say("Still saved to the mission log.")
        return true
    }

    private func say(_ text: String) {
        captureNote = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.captureNote == text { self?.captureNote = nil }
        }
    }

    /// The pictures a simulator sends, since it has no camera.
    private static func defaultSource() -> FrameSource {
        #if targetEnvironment(simulator)
        PatternSource()
        #else
        CameraSource()
        #endif
    }

    /// Called on a member's phone when an order it didn't have arrives: the app buzzes.
    var orderArrived: ((Order) -> Void)?
    /// On a member's phone: what it answered.
    private(set) var myAnswers: [UUID: OrderAck.Response] = [:]
    /// Orders the leader took back.
    private(set) var cancelledOrders: Set<UUID> = []

    private(set) var watchingObservers: [SquadObserver] = []
    private(set) var zones: [SquadZone] = []
    private(set) var zoneEvents: [ZoneEvent] = []
    private(set) var zoneAlert: ZoneEvent?
    private var seenZoneEvents: Set<UUID> = []
    private var receivedZoneSnapshot = false

    let device: UUID
    private let defaults: UserDefaults
    private let keychain: SquadKeychain
    private let folder: URL
    private let service: SquadService
    private let location = LocationTracker()
    private let compass = Compass()
    /// Which way this device is pointing, for its own arrow on the map. Nil without a compass.
    var heading: Double? { compass.heading }
    private var ticker: Task<Void, Never>?

    private var core: SquadCore<VideoMission>?
    private var lastSaved: LeaderSaved?
    private var host: SquadLinkHost?
    private var relayHost: RelayLinkHost?
    private var client: SquadLinkClient?
    private var enroller: SquadEnroller?
    /// For tests: where a member connects instead of looking the leader up with Bonjour.
    var fixedEndpoint: (() -> NWEndpoint?)?
    /// Seconds a member looks for the squad on this network before going through its relay.
    var relayAfter: TimeInterval = 3

    /// Seconds between position reports, until the squad's leader says otherwise.
    static let defaultReportEvery = 10
    /// The rates a leader can pick, in seconds.
    static let reportRates = [2, 5, 10, 30, 60]
    /// Seconds between this device's position reports: the leader's choice, which every device
    /// in the squad follows.
    private(set) var reportEvery = AppModel.defaultReportEvery

    init(defaults: UserDefaults = .standard, keychainService: String = "com.zacelston.squadz.squads",
         folder: URL = URL.applicationSupportDirectory, service: SquadService = .squadz, advertise: Bool = true) {
        self.defaults = defaults
        keychain = SquadKeychain(service: keychainService)
        self.folder = folder
        logs = MissionLogStore(root: folder.appendingPathComponent("missions"))
        self.service = service
        self.advertise = advertise
        if let saved = defaults.string(forKey: "device").flatMap(UUID.init(uuidString:)) {
            device = saved
        } else {
            device = UUID()
            defaults.set(device.uuidString, forKey: "device")
        }
    }

    private let advertise: Bool
    var hostPort: UInt16? { host?.port }
    var hostIsListening: Bool { host?.isListening == true }

    // MARK: Who's where

    var located: [Located] {
        (squad?.members ?? []).map { m in
            let others = role == .leader && m.id != me
            return Located(member: m, position: positions[m.id], isMe: m.id == me, isLeader: m.id == leaderID,
                           link: others ? (links[m.id] ?? .away) : nil,
                           joined: others ? core?.credentials.first { $0.member == m.id && !$0.revoked }?.issued : nil)
        }
    }

    /// On the leader's device: which members are linked right now, and how.
    private var links: [MemberID: MemberLink] = [:]

    private func refreshLinks() {
        var now: [MemberID: MemberLink] = [:]
        for (peer, member) in core?.peers ?? [:] {
            now[member] = relayHost?.connections[peer] != nil ? .relay : .direct
        }
        if now != links { links = now }
    }

    // MARK: Launch

    /// Picks up where the app left off: leading a squad, or a member of one.
    func resume() {
        guard role == .none else { return }
        if let saved = loadLeader(), let keys = try? keychain.leaderKeys(for: saved.squad.id) {
            lead(SquadCore(squad: saved.squad, mission: VideoMission(), keys: keys, credentials: saved.credentials,
                           epoch: saved.epoch, keyChanges: saved.keyChanges, revision: saved.revision, sharesPositions: true, sharesNotes: true, zones: saved.zones ?? [], zoneEvents: saved.zoneEvents ?? []),
                 me: saved.me, relay: saved.relay)
        } else if let id = defaults.string(forKey: "memberSquad").flatMap(UUID.init(uuidString:)),
                  let credential = try? keychain.credential(for: SquadID(id)) {
            connect(credential)
        }
    }

    /// The app came back to the front: links that dropped while it was away come back now.
    func foreground() {
        host?.restart()
        relayHost?.retryNow()
        client?.retryNow()
    }

    // MARK: Leading

    /// The relay new squads are started with, as typed on the home screen. Nil for none.
    /// Throws nothing: a relay that doesn't read as an address is reported by `startSquad`.
    private var relaySetting: (text: String, address: RelayAddress?) {
        let text = (defaults.string(forKey: "relayURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, RelayAddress(text: text, pin: defaults.string(forKey: "relayPin")))
    }

    func startSquad(name squadName: String, as myName: String) {
        guard role == .none else { return }
        let relay = relaySetting
        guard relay.text.isEmpty || relay.address != nil else {
            alert = "The relay's address or certificate fingerprint doesn't look right. Fix it or clear it, then start the squad."
            return
        }
        let mine = Member(name: myName, device: device)
        let core = SquadCore(squad: Squad(name: squadName, members: [mine]), mission: VideoMission(), sharesPositions: true, sharesNotes: true)
        do {
            try keychain.save(core.keys, for: core.squadID)
        } catch {
            alert = "Couldn't save this squad's keys, so it wasn't started."
            return
        }
        lead(core, me: mine.id, relay: relay.address)
        if role != .leader { try? keychain.removeLeaderKeys(for: core.squadID) }
    }

    private func lead(_ core: SquadCore<VideoMission>, me: MemberID, relay: RelayAddress?) {
        do {
            let host = try SquadLinkHost(name: core.squad.name, keys: core.linkKeys(now: .now), service: service,
                                         txt: [SquadService.Key.tag: core.squadID.tag], advertise: advertise)
            host.onOpened = { [weak self] peer, identity in
                MainActor.assumeIsolated { self?.core?.linkOpened(peer, identity: identity) }
            }
            host.onMessage = { [weak self] message, peer in
                MainActor.assumeIsolated {
                    // Pictures go to the screen, not through the squad's state.
                    if case let .mission(m) = message.body, let frame = VideoMission.frame(in: m) {
                        self?.show(frame, from: peer)
                        return
                    }
                    self?.updateLeader { $0.handle(message, from: peer, now: .now) }
                }
            }
            host.onPeerClosed = { [weak self] peer in MainActor.assumeIsolated { self?.updateLeader { $0.peerClosed(peer) } } }
            host.onFailed = { [weak self] _ in MainActor.assumeIsolated { self?.linkProblem = "Restarting the squad's link…" } }
            host.onReady = { [weak self] _ in MainActor.assumeIsolated { self?.linkProblem = nil } }
            do {
                try saveLeader(core, me: me, relay: relay)
            } catch {
                alert = "Couldn't save this squad on this phone. Check available storage and try again."
                return
            }
            self.core = core
            seenZoneEvents = Set(core.zoneEvents.map(\.id))
            self.host = host
            self.me = me
            leaderID = me
            role = .leader
            // The squad's log: a new one, or the one this squad already has after a restart.
            // Whoever is on the roster now is not joining now: at the start that is the leader alone.
            logger = MissionLogger(resuming: core)
            if logs.begin(core.squadID.raw, name: core.squad.name, now: .now) {
                logs.append([LogEntry(time: .now, kind: .squadStarted, name: core.squad.members.first { $0.id == me }?.name, text: core.squad.name)], to: core.squadID.raw)
            }
            leadingRelay = relay
            // The leader's rate from last time carries to this squad; everyone hears it as they join.
            if let chosen = defaults.object(forKey: "reportEvery") as? Int {
                _ = self.core?.setReportEvery(chosen, now: .now)
            }
            reportEvery = self.core?.reportEvery ?? Self.defaultReportEvery
            host.start()
            if let relay { openRoom(on: relay, for: core) }
            sent([])
            startReporting()
        } catch {
            alert = "Couldn't start the squad's link: \(error.localizedDescription)"
        }
    }

    private var leadingRelay: RelayAddress?

    /// The squad's room on its relay. Members' links arrive through it exactly as they do from
    /// the local network, and the core treats them the same.
    private func openRoom(on relay: RelayAddress, for core: SquadCore<VideoMission>) {
        let id = core.squadID
        let room = RelayLinkHost(address: relay, squad: id, token: try? keychain.relayToken(for: id),
                                 keys: core.linkKeys(now: .now), invites: core.relayInvites(now: .now))
        room.onOpened = { [weak self] peer, identity in
            MainActor.assumeIsolated { self?.core?.linkOpened(peer, identity: identity) }
        }
        room.onMessage = { [weak self] message, peer in
            MainActor.assumeIsolated {
                if case let .mission(m) = message.body, let frame = VideoMission.frame(in: m) {
                    self?.show(frame, from: peer)
                    return
                }
                self?.updateLeader { $0.handle(message, from: peer, now: .now) }
            }
        }
        room.onPeerClosed = { [weak self] peer in MainActor.assumeIsolated { self?.updateLeader { $0.peerClosed(peer) } } }
        room.onToken = { [weak self] token in MainActor.assumeIsolated { try? self?.keychain.save(relayToken: token, for: id) } }
        room.onStatus = { [weak self] status in
            MainActor.assumeIsolated {
                switch status {
                case .connecting: self?.relayNote = "Relay: connecting…"
                case .open: self?.relayNote = "Relay: open"
                case .retrying: self?.relayNote = "Relay: can't reach it. Trying again…"
                case let .stopped(why): self?.relayNote = "Relay: off. \(why)"
                }
            }
        }
        relayHost = room
        relayNote = "Relay: connecting…"
        room.start()
    }

    /// A reply can hand a member their credential. Keep the state it depends on
    /// before sending it or installing the new link keys.
    private func updateLeader(_ change: (inout SquadCore<VideoMission>) -> [Outgoing]) {
        guard var next = core, let me else { return }
        let out = change(&next)
        do {
            try saveLeader(next, me: me, relay: leadingRelay)
        } catch {
            for reply in out {
                if case .enrolled = reply.body {
                    let refusal = [Outgoing(to: reply.to, .refused("The leader couldn't save your membership. Try joining again."), thenClose: true)]
                    host?.send(refusal)
                    relayHost?.send(refusal)
                }
            }
            alert = "Couldn't save the squad change. Check available storage and try again."
            return
        }
        core = next
        sent(out)
    }

    private func sent(_ out: [Outgoing]) {
        guard let core, let host else { return }
        host.send(out)
        host.setKeys(core.linkKeys(now: .now))
        relayHost?.send(out)
        relayHost?.setKeys(core.linkKeys(now: .now), invites: core.relayInvites(now: .now))
        squad = core.squad
        positions = core.positions
        orders = core.orders.reversed()
        answers = core.acks
        let live = core.mission.active(core: core.view)
        if live.isEmpty, !streams.isEmpty { display.clear() }
        streams = live
        videoKbps = core.mission.kbps
        // A stream that ended takes its recording with it: close the clip.
        if let recording, !live.contains(where: { $0.id == recording.stream }) { endRecording(tellSquad: false) }
        log(logger.changes(in: core, streams: live, now: .now))
        notes = core.notes
        cancelledOrders = core.cancelled
        watchingObservers = core.observerRoster
        receiveZones(core.zones, events: core.zoneEvents, announce: true)
        refreshLinks()
        if let latest = core.notices.last {
            tell(latest)
        }
        if let invite, invite.isExpired(now: .now) || !core.invitations.contains(where: { $0.secret == invite.enrol }) {
            self.invite = nil
        }
    }

    /// Opens joining and returns the invite to show. Anyone who scans it before it expires joins.
    func openJoining() {
        guard var core else { return }
        core.closeJoining()
        invite = core.openJoining(now: .now, by: squad?.members.first { $0.id == me }?.name)
        // The invite names the relay only once the relay has a room for this squad.
        if let relayHost, relayHost.hasRoom { invite?.relay = relayHost.address }
        self.core = core
        sent([])
    }

    func closeJoining() {
        core?.closeJoining()
        invite = nil
        sent([])
    }

    func remove(_ member: MemberID) {
        guard member != me else { return }
        updateLeader { $0.removeMember(member, now: .now) }
    }

    func removeObserver(_ observer: SquadObserver) {
        guard role == .leader, let id = Data(hex: observer.id) else { return }
        updateLeader { $0.revoke(credential: id, now: .now) }
    }

    /// The leader sets how often every device in the squad sends its position.
    func setReportEvery(_ seconds: Int) {
        guard role == .leader else { return }
        defaults.set(seconds, forKey: "reportEvery")
        updateLeader { $0.setReportEvery(seconds, now: .now) }
        follow(core?.reportEvery)
    }

    /// Takes up a new rate, from the next report on.
    private func follow(_ seconds: Int?) {
        let rate = seconds ?? Self.defaultReportEvery
        guard rate != reportEvery else { return }
        reportEvery = rate
        if ticker != nil { startReporting() }
    }

    // MARK: Zones

    @discardableResult
    func saveZone(_ zone: SquadZone) -> Bool {
        guard role == .leader else { return false }
        if let error = zone.validationError { alert = error; return false }
        var next = zones.filter { $0.id != zone.id }
        next.append(zone)
        updateLeader { $0.setZones(next, now: .now) }
        if zones != next { alert = core?.lastProblem ?? "The zone could not be saved."; return false }
        return true
    }

    func deleteZone(_ zone: SquadZone) {
        guard role == .leader else { return }
        updateLeader { $0.setZones(zones.filter { $0.id != zone.id }, now: .now) }
    }

    func enableZoneNotifications() async {
        do {
            let enabled = try await ZoneNotifications.shared.enable()
            if !enabled {
                alert = "Notification banners are off. You can enable them for Squadz in Settings. Zone activity remains available in the app."
            }
        } catch { alert = "Could not enable notifications: \(error.localizedDescription)" }
    }

    private func receiveZones(_ zones: [SquadZone], events: [ZoneEvent], announce: Bool) {
        self.zones = zones
        zoneEvents = events
        let new = events.filter { !seenZoneEvents.contains($0.id) }
        seenZoneEvents.formUnion(events.map(\.id))
        // Retain only the bounded snapshot; old IDs cannot be broadcast again by the core.
        seenZoneEvents.formIntersection(Set(events.map(\.id)))
        guard announce else { return }
        for event in new where (role == .leader || event.member == me) && abs(event.time.timeIntervalSinceNow) <= 120 {
            zoneAlert = event
            ZoneNotifications.shared.post(event)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                if self?.zoneAlert?.id == event.id { self?.zoneAlert = nil }
            }
        }
    }

    // MARK: Field notes

    /// Says something to the whole squad, with where this device is. False if there was nothing to say.
    @discardableResult
    func sendNote(_ text: String) -> Bool {
        let words = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FieldNote.maxText))
        guard !words.isEmpty, let me else { return false }
        let mine = positions[me]
        let name = squad?.members.first { $0.id == me }?.name ?? defaults.string(forKey: "displayName") ?? ""
        let note = FieldNote(author: name, time: .now, at: mine?.at, accuracy: mine?.accuracy, text: words)
        switch role {
        case .leader:
            myNotes.insert(note.id)
            updateLeader { $0.postNote(note) }
        case .member:
            // The leader's device passes it to everyone else, not back here.
            notes.append(note)
            myNotes.insert(note.id)
            client?.send(.note(note))
        case .none:
            return false
        }
        notesRead = notes.count
        return true
    }

    /// The notes this device wrote, to show them on its own side of the chat.
    private var myNotes: Set<UUID> = []

    func isMine(_ note: FieldNote) -> Bool { myNotes.contains(note.id) }

    /// The notes tab is on screen: nothing is unread.
    func markNotesRead() {
        if notesRead != notes.count { notesRead = notes.count }
    }

    // MARK: Orders

    /// Sends an order to some members, or to everyone if `to` is empty. A move-to order needs a
    /// place. False if it wasn't sent.
    @discardableResult
    func sendOrder(_ kind: Order.Kind, text: String, at place: GeoPoint? = nil, to: Set<MemberID> = []) -> Bool {
        guard role == .leader, kind != .moveTo || place != nil else { return false }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind != .note || !words.isEmpty else { return false }
        let before = core?.orders.count ?? 0
        // Sending the same people somewhere new replaces where they were sent before.
        let replaced = kind == .moveTo ? openOrders.filter { $0.kind == .moveTo && Set($0.to ?? []) == to } : []
        updateLeader { $0.sendOrder(kind, text: words, at: place, to: to.isEmpty ? nil : Array(to), now: .now) }
        guard (core?.orders.count ?? 0) > before else { return false }
        for old in replaced { cancelOrder(old) }
        return true
    }

    /// Takes an order back: the phones it was for drop it.
    func cancelOrder(_ order: Order) {
        guard role == .leader else { return }
        updateLeader { $0.cancelOrder(order.id, now: .now) }
    }

    /// Who an order is for, without the leader, who gave it.
    func recipients(of order: Order) -> [Member] {
        (squad?.members ?? []).filter { order.isFor($0.id) && $0.id != leaderID }
    }

    /// True once everyone an order is for has answered done or can't, or has left.
    func isSettled(_ order: Order) -> Bool {
        if cancelledOrders.contains(order.id) { return true }
        switch role {
        case .leader:
            return recipients(of: order).allSatisfy { m in
                let a = answers[order.id]?[m.id]
                return a == .done || a == .cannot
            }
        case .member:
            let a = myAnswers[order.id]
            return a == .done || a == .cannot
        case .none:
            return true
        }
    }

    /// Orders still to be carried out, newest first: for the map, and for a member's card.
    var openOrders: [Order] { orders.filter { !isSettled($0) } }

    /// How an order stands, for its colour.
    enum OrderTone: Equatable {
        /// For the whole squad, and not yet seen.
        case team
        /// For particular people, and not yet seen.
        case personal
        case seen
        case cannot
    }

    /// On a phone, by what it answered. On the leader's device, by what everyone it was for
    /// answered: seen once they all have, can't once they all said so.
    func tone(of order: Order) -> OrderTone {
        let fresh: OrderTone = order.to == nil ? .team : .personal
        switch role {
        case .member:
            switch myAnswers[order.id] {
            case .cannot: return .cannot
            case .seen, .done: return .seen
            case nil: return fresh
            }
        case .leader:
            let given = recipients(of: order).map { answers[order.id]?[$0.id] }
            if given.isEmpty { return fresh }
            if given.allSatisfy({ $0 == .cannot }) { return .cannot }
            if given.allSatisfy({ $0 != nil }) { return .seen }
            return fresh
        case .none:
            return fresh
        }
    }

    /// On a member's phone: the newest order it hasn't answered at all, to put in front of them
    /// wherever they are in the app.
    var newOrder: Order? { openOrders.first { myAnswers[$0.id] == nil } }

    /// The same orders in the order they came, oldest first: what to do next is first.
    var queue: [Order] { openOrders.reversed() }

    /// A member's answer to an order.
    func answer(_ order: Order, _ response: OrderAck.Response) {
        guard role == .member, orders.contains(where: { $0.id == order.id }), !cancelledOrders.contains(order.id) else { return }
        myAnswers[order.id] = response
        client?.send(.orderAck(OrderAck(order: order.id, response: response)))
    }

    /// Ends the squad: everyone is cut off and nothing of it is kept.
    func endSquad() {
        guard role == .leader, let id = core?.squadID else { return }
        endRecording(tellSquad: false)
        log([LogEntry(time: .now, kind: .squadEnded, text: squad?.name)])
        logs.end(id.raw, now: .now)
        if let out = core?.resetSquad(now: .now) {
            host?.send(out)
            relayHost?.send(out)
        }
        // Let the goodbyes go before the links close. The relay forgets the squad too.
        let host = host, relayHost = relayHost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            host?.stop()
            relayHost?.stop(endSquad: true)
        }
        try? keychain.removeLeaderKeys(for: id)
        try? keychain.removeRelayToken(for: id)
        try? FileManager.default.removeItem(at: leaderFile)
        clear()
    }

    private var leaderFile: URL { folder.appendingPathComponent("leading.json") }

    private func saveLeader(_ core: SquadCore<VideoMission>, me: MemberID, relay: RelayAddress?) throws {
        let saved = LeaderSaved(squad: core.squad, me: me, credentials: core.credentials, epoch: core.epoch,
                                keyChanges: core.keyChanges, revision: core.revision, relay: relay, zones: core.zones, zoneEvents: core.zoneEvents)
        guard saved != lastSaved else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: leaderFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastSaved = saved
    }

    private func loadLeader() -> LeaderSaved? {
        (try? Data(contentsOf: leaderFile)).flatMap { try? JSONDecoder().decode(LeaderSaved.self, from: $0) }
    }

    // MARK: Joining

    /// A scanned code or an opened link. It only offers: joining takes a tap on `join`.
    func offer(_ text: String) {
        guard role == .none, !joining else {
            alert = role == .none ? nil : "Leave this squad before joining another."
            return
        }
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let invite = try? SquadInvite(url: url, scheme: service.scheme) else {
            alert = "That isn't a Squadz invite."
            return
        }
        guard !invite.isExpired(now: .now) else {
            alert = "This invite has expired. Ask for a new one."
            return
        }
        offered = invite
    }

    func join(_ invite: SquadInvite, as name: String) {
        guard role == .none, !joining else { return }
        offered = nil
        joining = true
        let enroller = SquadEnroller(invite: invite, name: name, device: device, service: service)
        enroller.fixedEndpoint = fixedEndpoint?()
        enroller.relayAfter = relayAfter
        enroller.onDone = { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.joining = false
                self.enroller = nil
                switch result {
                case let .success(credential):
                    do {
                        try self.keychain.save(credential)
                    } catch {
                        self.alert = "Joined, but couldn't keep the squad's key on this phone. Ask for a new invite."
                        return
                    }
                    self.defaults.set(credential.squad.raw.uuidString, forKey: "memberSquad")
                    self.connect(credential)
                case let .failure(why):
                    self.alert = why.reason
                }
            }
        }
        self.enroller = enroller
        enroller.start()
    }

    // MARK: A member

    private func connect(_ credential: MemberCredential) {
        let name = defaults.string(forKey: "displayName") ?? ""
        let client = SquadLinkClient(credential: credential, name: name, device: device, service: service)
        client.fixedEndpoint = fixedEndpoint?()
        client.relayAfter = relayAfter
        client.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.received(message.body) } }
        client.onStatus = { [weak self] status in MainActor.assumeIsolated { self?.linkChanged(status, squad: credential.squad) } }
        client.onCredentialChanged = { [weak self] new in MainActor.assumeIsolated { try? self?.keychain.save(new) } }
        self.client = client
        me = credential.member
        squad = Squad(id: credential.squad, name: credential.squadName)
        role = .member
        linkProblem = "Looking for \(credential.squadName)…"
        client.start()
        startReporting()
    }

    private func received(_ body: SquadMessage.Body) {
        switch body {
        case let .welcome(w):
            me = w.member
            show(w.squad)
        case let .status(s):
            show(s.squad)
            follow(s.reportEvery)
            watchingObservers = s.observers ?? []
            receiveZones(s.zones ?? [], events: s.zoneEvents ?? [], announce: receivedZoneSnapshot)
            receivedZoneSnapshot = true
            if let video = VideoMission.status(in: s) {
                streams = video.streams
                videoKbps = video.kbps
            }
        case let .mission(m):
            // The leader's device ending this phone's stream, or turning it down.
            guard let control = VideoMission.control(in: m), control.stream == myStream else { break }
            endStream(tellLeader: false)
            if control.t == .refused { alert = control.why ?? "The leader's device didn't take the stream." }
        case let .positions(report):
            for p in report.positions { if let m = p.member { positions[m] = p } }
        case let .notice(n):
            if let m = n.member { positions[m] = nil }
            tell(n)
        case let .order(o):
            // The leader's device sends an order again when this phone reconnects, until it is
            // answered done or can't.
            guard let me, o.isFor(me), !orders.contains(where: { $0.id == o.id }) else { break }
            orders.insert(o, at: 0)
            orders.sort { $0.time > $1.time }
            orderArrived?(o)
        case let .orderCancel(id):
            cancelledOrders.insert(id)
        case let .note(n):
            guard !notes.contains(where: { $0.id == n.id }) else { break }
            notes.append(n)
            notes.sort { $0.time < $1.time }
        default:
            break
        }
    }

    private func show(_ new: Squad) {
        squad = new
        // The leader put itself first on the roster when it started the squad.
        leaderID = new.members.first?.id
        let roster = Set(new.members.map(\.id))
        positions = positions.filter { roster.contains($0.key) }
    }

    private func linkChanged(_ status: SquadLinkClient.Status, squad id: SquadID) {
        switch status {
        case .connected:
            linkProblem = nil
            relayNote = client?.isRelayed == true ? "Connected through the relay" : nil
            report()
        case .searching, .connecting:
            relayNote = nil
            linkProblem = "Looking for \(squad?.name ?? "the squad")…"
        case .reconnecting:
            relayNote = nil
            linkProblem = "Lost the link to \(squad?.name ?? "the squad"). Trying again…"
        case let .stopped(why):
            guard role == .member, why != "Left" else { return }
            // The leader won't have this phone back: forget the squad.
            forgetMembership(of: id)
            alert = why
        }
    }

    func leaveSquad() {
        guard role == .member, let id = squad?.id else { return }
        // For good: the leader's device takes this phone off the squad and tells the others.
        client?.stop(forGood: true)
        forgetMembership(of: id)
    }

    private func forgetMembership(of id: SquadID) {
        try? keychain.removeCredential(for: id)
        defaults.removeObject(forKey: "memberSquad")
        clear()
    }

    private var shownNotice: UUID?

    /// Shows a notice for a quarter of a minute.
    private func tell(_ n: Notice) {
        guard n.id != shownNotice else { return }
        shownNotice = n.id
        notice = n
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if self?.notice?.id == n.id { self?.notice = nil }
        }
    }

    private func clear() {
        notice = nil
        watchingObservers = []
        zones = []
        zoneEvents = []
        zoneAlert = nil
        seenZoneEvents = []
        receivedZoneSnapshot = false
        orders = []
        answers = [:]
        myAnswers = [:]
        cancelledOrders = []
        streamer?.stop()
        streamer = nil
        myStream = nil
        streams = []
        endRecording(tellSquad: false)
        display.clear()
        reportEvery = Self.defaultReportEvery
        notes = []
        notesRead = 0
        myNotes = []
        links = [:]
        ticker?.cancel()
        ticker = nil
        location.stop()
        compass.stop()
        client = nil
        host = nil
        relayHost = nil
        leadingRelay = nil
        relayNote = nil
        core = nil
        lastSaved = nil
        role = .none
        squad = nil
        me = nil
        leaderID = nil
        positions = [:]
        linkProblem = nil
        invite = nil
    }

    // MARK: Positions

    private func startReporting() {
        compass.start()
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.report()
                try? await Task.sleep(for: .seconds(self?.reportEvery ?? Self.defaultReportEvery))
            }
        }
    }

    /// This phone's position, to the squad.
    private func report() {
        guard let me else { return }
        location.start()
        guard var position = location.latest() else { return }
        // Which way the device points is known standing still; which way it is moving is not.
        if let heading = compass.heading { position.heading = heading.rounded() }
        setMyPosition(position, member: me)
    }

    /// Also the way tests place this phone.
    func setMyPosition(_ position: MemberPosition, member me: MemberID) {
        var mine = position
        mine.member = me
        switch role {
        case .leader:
            updateLeader { $0.setPosition(position, of: me) }
        case .member:
            positions[me] = mine
            client?.send(.position(position))
        case .none:
            break
        }
    }
}
