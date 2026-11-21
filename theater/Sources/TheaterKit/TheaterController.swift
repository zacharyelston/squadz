import Foundation
import Network
import SquadKit
import SquadLink

public struct NearbySquad: Encodable { public var name: String; public var compatible: Bool }
public struct TheaterSnapshot: Encodable {
    public var squads: [SquadViewState]
    public var nearby: [NearbySquad]
    public var problem: String?
    public var tiles: Bool
    public var demoMap: Bool
    public var tileAttribution: String
    public var tileMaxZoom: Int
}

@MainActor
public final class TheaterController {
    public var onChange: (() -> Void)?
    public var fixedEndpoint: ((SquadID) -> NWEndpoint?)?
    public private(set) var squads: [SquadID: ObservedSquad] = [:]
    private var clients: [SquadID: SquadLinkClient] = [:]
    private var enrollers: [SquadID: SquadEnroller] = [:]
    private var demoSquads: Set<SquadID> = []
    private var nearby: [NearbySquad] = []
    private var problem: String?
    private let browser: SquadBrowser
    private let service: SquadService
    private let folder: URL
    private let keychain: SquadKeychain
    private var known: [SquadID] = []
    private let device: UUID
    private let persist: Bool
    public let options: TheaterOptions

    public init(options: TheaterOptions, service: SquadService = .squadz, persist: Bool = true) throws {
        try options.validate()
        let savesCredentials = persist && !options.fixture
        self.options = options; self.service = service; self.folder = options.dataDirectory; self.persist = savesCredentials
        keychain = SquadKeychain(service: "org.squadz.theater.observers")
        browser = SquadBrowser(service: service)
        if savesCredentials {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let deviceFile = folder.appendingPathComponent("device.txt")
            if let text = try? String(contentsOf: deviceFile), let id = UUID(uuidString: text) { device = id }
            else {
                device = UUID(); try device.uuidString.write(to: deviceFile, atomically: true, encoding: .utf8)
            }
        } else { device = UUID() }
        browser.onChange = { [weak self] values in
            MainActor.assumeIsolated {
                self?.nearby = values.map { NearbySquad(name: $0.name, compatible: $0.isCompatible) }; self?.onChange?()
            }
        }
        browser.onFailed = { [weak self] _ in MainActor.assumeIsolated {
            self?.problem = "Nearby discovery is unavailable. Allow local network access for the terminal, then restart."; self?.onChange?()
        } }
    }

    public func start(discover: Bool = true) {
        if discover { browser.start() }
        guard persist else { return }
        let file = folder.appendingPathComponent("squads.json")
        known = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SquadID].self, from: $0) } ?? []
        for id in known {
            if let credential = try? keychain.credential(for: id), credential.role == .observer, credential.member == nil { connect(credential) }
        }
    }

    func allowDemoSquad(_ id: SquadID) { demoSquads.insert(id) }

    /// The only squad handshake is enrollment as an observer. No member fallback is possible.
    public func join(_ text: String, name: String = "Theater") throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw TheaterError.message("Paste a squad invite link.") }
        var invite: SquadInvite
        do { invite = try SquadInvite(url: url, scheme: service.scheme) } catch { throw TheaterError.message("That is not a valid invite for this app.") }
        guard !options.demoMap || demoSquads.contains(invite.squad) else {
            throw TheaterError.message("Online demo maps only support generated sample squads. Run without --demo-map to join a real squad.")
        }
        guard !invite.isExpired(now: .now) else { throw TheaterError.message("The invite expired. Ask the leader for a new one.") }
        guard clients[invite.squad] == nil, enrollers[invite.squad] == nil else { throw TheaterError.message("This squad is already connected or joining.") }
        guard squads.count < 16 else { throw TheaterError.message("This host already watches 16 squads.") }
        invite.relay = nil // This issue is local-network only, even if the invite names a relay.
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let enroller = SquadEnroller(invite: invite, name: name.isEmpty ? "Theater" : name, device: device, role: .observer, service: service)
        enroller.fixedEndpoint = fixedEndpoint?(invite.squad)
        squads[invite.squad] = ObservedSquad(squad: Squad(id: invite.squad, name: invite.name))
        enrollers[invite.squad] = enroller
        let id = invite.squad
        enroller.onDone = { [weak self] result in MainActor.assumeIsolated {
            guard let self else { return }
            self.enrollers[id] = nil
            switch result {
            case var .success(credential):
                guard credential.role == .observer, credential.member == nil else {
                    self.failed(id, "The leader did not issue an observer credential."); return
                }
                credential.relay = nil
                do {
                    if self.persist { try self.keychain.save(credential) }
                    if !self.known.contains(id) { self.known.append(id) }
                    try self.saveKnown()
                    self.connect(credential)
                } catch { self.failed(id, "Could not save the observer credential in Keychain.") }
            case .failure: self.failed(id, "Could not join. Check the invite, leader, and local-network permission.")
            }
        } }
        onChange?(); enroller.start()
    }

    private func connect(_ value: MemberCredential) {
        var credential = value; credential.relay = nil
        guard credential.role == .observer, credential.member == nil else { return }
        if squads[credential.squad] == nil { squads[credential.squad] = ObservedSquad(squad: Squad(id: credential.squad, name: credential.squadName)) }
        let id = credential.squad
        let client = SquadLinkClient(credential: credential, name: "Theater", device: device, service: service)
        client.fixedEndpoint = fixedEndpoint?(id)
        client.onMessage = { [weak self] message in MainActor.assumeIsolated {
            self?.squads[id]?.receive(message.body); self?.onChange?()
        } }
        client.onCredentialChanged = { [weak self] changed in MainActor.assumeIsolated {
            guard let self, self.persist else { return }; try? self.keychain.save(changed)
        } }
        client.onStatus = { [weak self] status in MainActor.assumeIsolated {
            guard let self else { return }
            switch status {
            case .connected: self.squads[id]?.connection = "connected"; self.squads[id]?.problem = nil
            case .searching, .connecting: self.squads[id]?.connection = "connecting"
            case .reconnecting: self.squads[id]?.connection = "disconnected"; self.squads[id]?.problem = "Link lost. Showing last known state; retrying locally."
            case .stopped:
                self.squads[id]?.connection = "removed"; self.squads[id]?.problem = "The leader no longer accepts this observer. Ask for a new invite."
                self.clients[id] = nil; self.known.removeAll { $0 == id }
                if self.persist { try? self.keychain.removeCredential(for: id); try? self.saveKnown() }
            }
            self.onChange?()
        } }
        clients[id] = client; client.start()
    }

    public func forget(_ id: SquadID) throws {
        if let client = clients.removeValue(forKey: id) { client.onStatus = nil; client.stop() }
        enrollers.removeValue(forKey: id)?.cancel()
        squads[id] = nil; known.removeAll { $0 == id }
        if persist { try keychain.removeCredential(for: id); try saveKnown() }
        onChange?()
    }
    public func stop() {
        browser.stop()
        // A local shutdown must retain the credential for the next launch. Only a refusal
        // from the leader revokes it; SquadLink also reports .stopped for a local stop.
        let active = Array(clients.values); clients = [:]
        for client in active { client.onStatus = nil; client.stop() }
        let joining = Array(enrollers.values); enrollers = [:]
        for joiner in joining { joiner.onDone = nil; joiner.cancel() }
    }
    private func failed(_ id: SquadID, _ message: String) { squads[id]?.connection = "failed"; squads[id]?.problem = message; onChange?() }
    private func saveKnown() throws {
        guard persist else { return }
        try JSONEncoder().encode(known).write(to: folder.appendingPathComponent("squads.json"), options: [.atomic])
    }
    public var snapshot: TheaterSnapshot {
        TheaterSnapshot(squads: squads.values.map(\.view).sorted { $0.name < $1.name }, nearby: nearby, problem: problem,
                        tiles: options.tilesDirectory != nil || options.demoMap, demoMap: options.demoMap,
                        tileAttribution: options.demoMap ? "© OpenStreetMap contributors" : options.tileAttribution,
                        tileMaxZoom: options.demoMap ? min(19, options.tileMaxZoom) : options.tileMaxZoom)
    }
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}
