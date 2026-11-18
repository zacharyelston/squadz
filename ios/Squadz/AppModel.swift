import Foundation
import Observation
import PairKit

/// Everything the screens show, and the one loop that talks to the server.
@MainActor
@Observable
final class AppModel {
    static let app = "squadz"

    private(set) var account: Account?
    private(set) var me: Me?
    private(set) var locations: [Located] = []
    /// A connection problem, shown as a banner while the app keeps trying.
    private(set) var connectionProblem: String?
    /// Something the user must read: a refusal, or being signed out.
    var alert: String?
    private(set) var busy = false
    /// An invite opened as a link before the user had given a name.
    private(set) var pendingCode: String?

    private let store = AccountStore(app: AppModel.app)
    private let tracker = LocationTracker()
    private var loop: Task<Void, Never>?
    private var lastSent: PositionReport?
    private var lastSentAt = Date.distantPast

    var client: Client? { account.map(Client.init) }
    var squad: SquadInfo? { me?.squad }

    init() {
        account = store.all().first
    }

    /// Runs while the app is on screen.
    func resume() {
        guard account != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(self?.me?.pollSeconds ?? 10))
            }
        }
    }

    func pause() {
        loop?.cancel()
        loop = nil
        tracker.stop()
    }

    private func restart() {
        pause()
        resume()
    }

    /// How often to repeat an unchanged position, so a phone that is sitting
    /// still never looks stale to the others.
    private var heartbeat: TimeInterval {
        TimeInterval(min(60, max(me?.pollSeconds ?? 10, (me?.staleSeconds ?? 300) / 3)))
    }

    /// One round: who am I, where am I, where is everyone.
    private func tick() async {
        guard let client else { return }
        do {
            if me == nil { me = try await client.send("GET", "api/v1/me") }
            guard me?.squad != nil else {
                me = try await client.send("GET", "api/v1/me")
                locations = []
                connectionProblem = nil
                return
            }
            tracker.start()
            if let position = tracker.latest,
               position != lastSent || Date.now.timeIntervalSince(lastSentAt) >= heartbeat {
                let _: Empty = try await client.send("PUT", "api/v1/location", body: position)
                lastSent = position
                lastSentAt = .now
            }
            let reply: LocationsReply = try await client.send("GET", "api/v1/squad/locations")
            locations = reply.locations
            if reply.squad != me?.squad { me = try await client.send("GET", "api/v1/me") }
            connectionProblem = nil
        } catch {
            await handle(error, quietly: true)
        }
    }

    private func handle(_ error: Error, quietly: Bool = false) async {
        switch error as? PairKitError {
        case .signedOut:
            if let account { await store.remove(account) }
            forget()
            alert = "This phone was signed out by the server. Scan a pairing code to join again."
        case .http(409, _, code: "no_squad"):
            me = nil // the squad is gone; the next round finds out where we stand
        case .unreachable, .pinMismatch, .clock:
            connectionProblem = error.localizedDescription
        default:
            if quietly { connectionProblem = error.localizedDescription } else { alert = error.localizedDescription }
        }
    }

    private func forget() {
        pause()
        if let account { try? FileManager.default.removeItem(at: ServerTileOverlay.cacheDirectory(account: account.id)) }
        account = nil
        me = nil
        locations = []
        connectionProblem = nil
        lastSent = nil
    }

    private func perform(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await work() } catch { await handle(error) }
    }

    // MARK: Invite links

    /// An invite as a link, for sending as text: squadz://pair?c=<base64url
    /// of the pairing code>. The code inside is the same one the QR holds.
    static func link(for code: String) -> URL? {
        let c = Data(code.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "squadz://pair?c=\(c)")
    }

    static func code(from link: URL) -> String? {
        guard link.scheme == "squadz", link.host() == "pair",
              var c = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "c" })?.value
        else { return nil }
        c = c.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        c += String(repeating: "=", count: (4 - c.count % 4) % 4)
        return Data(base64Encoded: c).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Someone tapped an invite link. Pair now if we know the user's name,
    /// otherwise keep the invite until they have typed one.
    func open(_ link: URL) async {
        guard let code = Self.code(from: link) else {
            alert = "That isn't a Squadz invite link."
            return
        }
        let name = me?.name ?? UserDefaults.standard.string(forKey: "displayName")?.trimmingCharacters(in: .whitespaces) ?? ""
        if name.isEmpty { pendingCode = code } else { await pair(code: code, name: name) }
    }

    // MARK: Actions

    /// Pairs with the server in a scanned or pasted code. A phone holds one
    /// pairing at a time: joining somewhere new leaves the old place first.
    func pair(code: String, name: String) async {
        pendingCode = nil
        let payload: PairingPayload
        do {
            payload = try PairingPayload.parse(code, app: Self.app)
        } catch {
            alert = switch error {
            case .version: "This code needs a newer version of Squadz."
            case .wrongApp: "That code is for a different app."
            case .notPayload, .badField: "That isn't a Squadz pairing code."
            }
            return
        }
        await perform {
            let (account, info): (Account, PairInfo) = try await Client.pair(payload, name: name, store: store)
            if let old = self.account { await Client(account: old).signOut(from: store) }
            forget()
            self.account = account
            _ = info
            resume()
        }
    }

    func createSquad(name: String) async {
        guard let client else { return }
        await perform {
            let _: SquadInfo = try await client.send("POST", "api/v1/squads", body: NameBody(name: name))
            me = try await client.send("GET", "api/v1/me")
            restart()
        }
    }

    func invite() async -> InviteReply? {
        guard let client else { return nil }
        var reply: InviteReply?
        await perform { reply = try await client.send("POST", "api/v1/squad/invites") }
        return reply
    }

    func leaveSquad() async {
        guard let client else { return }
        await perform {
            let _: Empty = try await client.send("POST", "api/v1/squad/leave")
            me = try await client.send("GET", "api/v1/me")
            locations = []
            tracker.stop()
        }
    }

    func signOut() async {
        guard let account else { return }
        busy = true
        await Client(account: account).signOut(from: store)
        busy = false
        forget()
    }
}
