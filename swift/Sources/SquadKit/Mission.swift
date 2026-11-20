import Foundation

/// A mission add-on to the squad core. The core does what every squad needs: join, roster,
/// positions, orders, notes, check fire and holds. A mission adds its own messages, state, holds,
/// order kinds and part of the status.
///
/// A mission's messages cross the wire as `.mission(id, version, payload)`. The core hands a
/// payload to the mission only when both the ID and the version match, so changing a mission
/// never changes the core's protocol version, and a device without the mission ignores it.
///
/// Holds only add: the core's holds and the mission's are unioned, and nothing a mission returns
/// can remove a core hold.
public protocol Mission {
    static var id: String { get }
    static var version: Int { get }
    /// Order kinds this mission adds to the core's.
    static var orderKinds: [Order.Kind] { get }

    /// A joined member's message for this mission.
    mutating func handle(_ payload: Data, from member: MemberID, peer: PeerID, core: CoreView, now: Date) -> MissionStep
    /// This mission's holds. The core adds them to its own.
    func holds(core: CoreView, now: Date) -> Set<Hold>
    /// Someone called check fire. The core has already raised its hold.
    mutating func checkFireRaised(core: CoreView)
    /// The role a member gets on first joining.
    func role(forNewMemberOf squad: Squad) -> MemberRole
    /// Payloads sent to an observer after `.observing`, before the first status.
    func observerWelcome(core: CoreView) -> [Data]
    /// This mission's part of the status, for members and observers. Nil for none.
    func status(core: CoreView, now: Date) -> Data?
}

public extension Mission {
    static var orderKinds: [Order.Kind] { [] }
    mutating func checkFireRaised(core: CoreView) {}
    func role(forNewMemberOf squad: Squad) -> MemberRole { .member }
    func observerWelcome(core: CoreView) -> [Data] { [] }
    func status(core: CoreView, now: Date) -> Data? { nil }
}

/// A squad with no mission: it shares positions, orders and notes, and anyone can call check fire.
public struct NoMission: Mission {
    public static let id = "none"
    public static let version = 1
    public init() {}
    public mutating func handle(_ payload: Data, from member: MemberID, peer: PeerID, core: CoreView, now: Date) -> MissionStep { .none }
    public func holds(core: CoreView, now: Date) -> Set<Hold> { [] }
}

/// What the core knows, as a mission sees it. Read-only.
public struct CoreView {
    public let squad: Squad
    public let positions: [MemberID: MemberPosition]
    public let peers: [PeerID: MemberID]
    public let observers: Set<PeerID>
    public let checkFire: CheckFire?

    public var squadID: SquadID { squad.id }

    /// The core's own holds.
    public var holds: Set<Hold> { checkFire.map { [.checkFire(by: $0.by)] } ?? [] }

    /// The link a member is on now, if any.
    public func peer(of member: MemberID) -> PeerID? {
        peers.first { $0.value == member }?.key
    }

    public func member(_ id: MemberID) -> Member? {
        squad.members.first { $0.id == id }
    }

    /// Every joined member's link, in a stable order.
    public var memberPeers: [PeerID] { peers.keys.sorted { $0.raw < $1.raw } }
    /// Every observer's link, in a stable order.
    public var observerPeers: [PeerID] { observers.sorted { $0.raw < $1.raw } }
}

/// What a mission's message or action did, for the core to finish.
public struct MissionStep {
    /// Sent first, in order.
    public var out: [Outgoing]
    /// The squad changed: the core bumps the revision and sends status to everyone.
    public var changed: Bool
    /// Status to everyone without a new revision.
    public var statusOnly: Bool
    /// Something went wrong, for the leader's screen.
    public var problem: String?
    /// The last problem is resolved.
    public var clearsProblem: Bool

    public init(_ out: [Outgoing] = [], changed: Bool = false, statusOnly: Bool = false,
                problem: String? = nil, clearsProblem: Bool = false) {
        self.out = out
        self.changed = changed
        self.statusOnly = statusOnly
        self.problem = problem
        self.clearsProblem = clearsProblem
    }

    public static let none = MissionStep()
    public static func changed(_ out: [Outgoing] = [], clearsProblem: Bool = false) -> MissionStep {
        MissionStep(out, changed: true, clearsProblem: clearsProblem)
    }
    public static func problem(_ text: String, _ out: [Outgoing] = []) -> MissionStep {
        MissionStep(out, problem: text)
    }
}
