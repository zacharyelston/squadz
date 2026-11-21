import Foundation

/// A visible observer credential, without its secret. Only the leader can revoke it.
public struct SquadObserver: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var joined: Date
    public var connected: Bool
}

public struct ObserverMemberConnection: Codable, Equatable, Sendable {
    public var member: MemberID
    public var connected: Bool
}

public struct ObserverOrderAnswer: Codable, Equatable, Sendable {
    public var order: UUID
    public var member: MemberID
    public var response: OrderAck.Response
}

/// Read-only telemetry sent to observers, never accepted from them or sent to ordinary members.
public struct ObserverTelemetry: Codable, Equatable, Sendable {
    public var connections: [ObserverMemberConnection]
    public var answers: [ObserverOrderAnswer]
}
