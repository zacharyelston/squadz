import Foundation
import Security
import SquadKit

/// Where a device keeps what lets it back into a squad: a member's credential, or the leader's
/// keys. One Keychain item per squad, readable after the first unlock (so a link can come back up
/// in the background), never synced and never in a backup restored to another device.
public struct SquadKeychain {
    public struct Failure: Error, Equatable {
        public var status: OSStatus
    }

    /// The Keychain service name, like "com.example.squadz.squads".
    public var service: String

    public init(service: String) {
        self.service = service
    }

    // MARK: A member's credential

    public func save(_ credential: MemberCredential) throws {
        try write(try JSONEncoder().encode(credential), account: "member." + credential.squad.raw.uuidString)
    }

    public func credential(for squad: SquadID) throws -> MemberCredential? {
        try read(account: "member." + squad.raw.uuidString).map { try JSONDecoder().decode(MemberCredential.self, from: $0) }
    }

    public func removeCredential(for squad: SquadID) throws {
        try delete(account: "member." + squad.raw.uuidString)
    }

    // MARK: The leader's keys

    public func save(_ keys: LeaderKeys, for squad: SquadID) throws {
        let exported = keys.exported
        try write(exported.root + exported.identity, account: "leader." + squad.raw.uuidString)
    }

    public func leaderKeys(for squad: SquadID) throws -> LeaderKeys? {
        guard let data = try read(account: "leader." + squad.raw.uuidString) else { return nil }
        guard data.count > 32 else { throw Failure(status: errSecDecode) }
        return try LeaderKeys(root: data.prefix(32), identity: data.dropFirst(32))
    }

    public func removeLeaderKeys(for squad: SquadID) throws {
        try delete(account: "leader." + squad.raw.uuidString)
    }

    // MARK: Items

    private func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private func write(_ data: Data, account: String) throws {
        var status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private func read(account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure(status: status) }
        return data
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
