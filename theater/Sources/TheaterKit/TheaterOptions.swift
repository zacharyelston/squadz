import Foundation
import Network
import SquadKit

public enum TheaterError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

public struct TheaterOptions {
    public var bind = "127.0.0.1"
    public var port: UInt16 = 8765
    public var tilesDirectory: URL?
    public var tileAttribution = "Local map tiles"
    public var tileMaxZoom = 18
    public var dataDirectory = URL.applicationSupportDirectory.appendingPathComponent("SquadzTheater")
    public var noHTTP = false
    public var inviteStdin = false
    public var fixture = false
    public var demoMap = false
    public var endpoint: NWEndpoint?
    public var observerName = "Theater"
    public init() {}
    public var isLoopback: Bool { Self.loopback(bind) }
    public static func loopback(_ host: String) -> Bool { host == "127.0.0.1" || host == "::1" }
    public static func localAddress(_ host: String) -> Bool {
        if loopback(host) { return true }
        guard let ip = IPv4Address(host) else { return false }
        let b = Array(ip.rawValue)
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }
    public func validate() throws {
        guard !demoMap || (fixture && tilesDirectory == nil && !inviteStdin) else {
            throw TheaterError.message("--demo-map requires --demo and cannot be combined with --tiles or --invite-stdin.")
        }
        guard Self.localAddress(bind) else { throw TheaterError.message("Bind to loopback or an explicit private/link-local IPv4 address. Wildcard and public listeners are not supported.") }
        guard isLoopback || port > 0 else { throw TheaterError.message("LAN mode needs an explicit nonzero port.") }
        guard (0...22).contains(tileMaxZoom) else { throw TheaterError.message("Tile zoom must be 0 through 22.") }
        if let tilesDirectory {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: tilesDirectory.path, isDirectory: &directory), directory.boolValue else { throw TheaterError.message("The tile directory does not exist.") }
        }
    }
    public static func parse(_ args: [String]) throws -> TheaterOptions {
        var result = TheaterOptions(), index = 0
        while index < args.count {
            let flag = args[index]; index += 1
            func value() throws -> String {
                guard index < args.count else { throw TheaterError.message("Missing value for \(flag).") }
                let text = args[index]; index += 1; return text
            }
            switch flag {
            case "--bind": result.bind = try value()
            case "--port": guard let n = UInt16(try value()) else { throw TheaterError.message("Port must be 0–65535.") }; result.port = n
            case "--tiles": result.tilesDirectory = URL(fileURLWithPath: try value()).standardizedFileURL
            case "--tile-attribution": result.tileAttribution = try value()
            case "--tile-max-zoom": guard let n = Int(try value()) else { throw TheaterError.message("Invalid tile zoom.") }; result.tileMaxZoom = n
            case "--data-dir": result.dataDirectory = URL(fileURLWithPath: try value())
            case "--name": result.observerName = try value()
            case "--invite-stdin": result.inviteStdin = true
            case "--no-http": result.noHTTP = true
            case "--demo": result.fixture = true
            case "--demo-map": result.demoMap = true
            case "--endpoint":
                let text = try value(), parts = text.split(separator: ":")
                guard parts.count == 2, localAddress(String(parts[0])), let n = UInt16(parts[1]), n > 0,
                      let port = NWEndpoint.Port(rawValue: n) else { throw TheaterError.message("Endpoint must be a local/private IPv4 address and port.") }
                result.endpoint = .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port)
            default: throw TheaterError.message("Unknown option: \(flag). Run --help for usage.")
            }
        }
        try result.validate(); return result
    }
}
