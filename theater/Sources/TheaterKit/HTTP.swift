import CryptoKit
import Foundation
import Network
import SquadKit

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public var loopback: Bool
    public var peer: String
}

/// A deliberately small HTTP/1.1 subset. No chunked uploads, pipelining or ambiguous framing.
public struct HTTPReader: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data, loopback: Bool, peer: String) throws -> HTTPRequest? {
        buffer.append(bytes)
        guard buffer.count <= 32_768 else { throw TheaterError.message("Request too large.") }
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16_384 { throw TheaterError.message("Headers too large.") }; return nil
        }
        guard range.lowerBound <= 16_384, let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw TheaterError.message("Invalid headers.") }
        let lines = head.components(separatedBy: "\r\n"), first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", first[1].hasPrefix("/"), !first[1].contains("#") else { throw TheaterError.message("Invalid request line.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw TheaterError.message("Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[name] == nil else { throw TheaterError.message("Duplicate or invalid header.") }
            headers[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw TheaterError.message("Chunked uploads are not supported.") }
        let size: Int
        if let text = headers["content-length"] {
            guard !text.isEmpty, text.allSatisfy(\.isNumber), let n = Int(text), n <= 16_384 else { throw TheaterError.message("Invalid content length.") }; size = n
        } else { size = 0 }
        let end = range.upperBound + size
        guard buffer.count >= end else { return nil }
        guard buffer.count == end else { throw TheaterError.message("Pipelined requests are not supported.") }
        let target = String(first[1])
        guard let url = URLComponents(string: target), url.scheme == nil, url.host == nil else { throw TheaterError.message("Invalid target.") }
        return HTTPRequest(method: String(first[0]), path: url.percentEncodedPath, headers: headers, body: Data(buffer[range.upperBound..<end]), loopback: loopback, peer: peer)
    }
}

@MainActor
public final class HTTPAccess {
    public let passcode: String?
    private let bind: String
    public var port: UInt16
    private var sessions: [String: Date] = [:]
    private var attempts: [String: (Int, Date)] = [:]
    public init(bind: String, port: UInt16, passcode: String? = nil) {
        self.bind = bind; self.port = port
        self.passcode = TheaterOptions.loopback(bind) ? nil : passcode ?? Data.random(9).base64URL
    }
    public func validHost(_ request: HTTPRequest) -> Bool {
        let hosts = ["127.0.0.1", "localhost", "[::1]", bind]
        let values = hosts.map { "\($0):\(port)" } + (port == 80 ? hosts : [])
        guard let host = request.headers["host"]?.lowercased(), values.contains(host) else { return false }
        if request.headers["sec-fetch-site"] == "cross-site" { return false }
        return true
    }
    public func validMutation(_ request: HTTPRequest) -> Bool {
        guard validHost(request), request.headers["x-theater-request"] == "1",
              request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let origin = request.headers["origin"], let host = request.headers["host"] else { return false }
        return origin == "http://\(host)"
    }
    public func authorized(_ request: HTTPRequest, now: Date = .now) -> Bool {
        if request.loopback { return true }
        guard passcode != nil, let token = request.headers["cookie"]?.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("theater=") }).map({ String($0.dropFirst(8)) }),
              let expires = sessions[token], expires > now else { return false }
        return true
    }
    public func login(_ code: String, peer: String, now: Date = .now) throws -> String {
        attempts = attempts.filter { now.timeIntervalSince($0.value.1) < 60 }
        guard (attempts[peer]?.0 ?? 0) < 8 else { throw TheaterError.message("Too many attempts. Wait a minute.") }
        if attempts.count >= 1024 && attempts[peer] == nil { throw TheaterError.message("Too many attempts. Wait a minute.") }
        attempts[peer] = ((attempts[peer]?.0 ?? 0) + 1, attempts[peer]?.1 ?? now)
        let actual = Array(SHA256.hash(data: Data(code.utf8)))
        let expected = Array(SHA256.hash(data: Data((passcode ?? "").utf8)))
        let difference = zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        guard passcode != nil, difference == 0 else { throw TheaterError.message("Incorrect passcode.") }
        sessions = sessions.filter { $0.value > now }
        guard sessions.count < 128 else { throw TheaterError.message("Too many active sessions.") }
        let token = Data.random(32).base64URL; sessions[token] = now.addingTimeInterval(8 * 3600); attempts[peer] = nil
        return token
    }
}

@MainActor
public final class TheaterHTTPServer {
    public var onReady: ((UInt16) -> Void)?
    public var onError: ((String) -> Void)?
    public private(set) var port: UInt16 = 0
    public let access: HTTPAccess
    private let controller: TheaterController
    private var listeners: [NWListener] = []
    private var connections: [UUID: NWConnection] = [:]
    private var streams: [UUID: Stream] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var publishing = false
    private struct Stream { var request: HTTPRequest; var sending = false; var pending: Data? }
    public init(controller: TheaterController) {
        self.controller = controller
        access = HTTPAccess(bind: controller.options.bind, port: controller.options.port)
    }
    public func start() throws {
        try listen(controller.options.bind, port: controller.options.port, primary: true)
        controller.onChange = { [weak self] in self?.broadcast() }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }
            for id in Array(self.streams.keys) {
                guard let stream = self.streams[id], self.access.authorized(stream.request) else { self.close(id); continue }
                if !stream.sending && stream.pending == nil { self.sendStream(id, data: Data(": heartbeat\n\n".utf8)) }
            }
        } }
        timer.resume(); heartbeat = timer
    }
    private func listen(_ bind: String, port: UInt16, primary: Bool) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in MainActor.assumeIsolated { self?.accept(connection) } }
        listener.stateUpdateHandler = { [weak self, weak listener] state in MainActor.assumeIsolated {
            guard let self else { return }
            switch state {
            case .ready where primary:
                self.port = listener?.port?.rawValue ?? port; self.access.port = self.port
                if !self.controller.options.isLoopback {
                    do { try self.listen("127.0.0.1", port: self.port, primary: false) }
                    catch { self.onError?("Could not start the local administration listener."); self.stop(); return }
                }
                self.onReady?(self.port)
            case .failed: self.onError?("Could not listen on the requested local address and port."); self.stop()
            default: break
            }
        } }
        listeners.append(listener); listener.start(queue: .main)
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 128 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in MainActor.assumeIsolated {
            switch state { case .failed, .cancelled: self?.close(id); default: break }
        } }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in MainActor.assumeIsolated {
            if self?.streams[id] == nil { self?.close(id) }
        } }
        receive(id, reader: HTTPReader())
    }
    private func receive(_ id: UUID, reader: HTTPReader) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in MainActor.assumeIsolated {
            guard let self else { return }
            var reader = reader
            do {
                let peer: String
                if case let .hostPort(host, _) = connection.endpoint { peer = String(describing: host) } else { peer = "unknown" }
                if let data, let request = try reader.append(data, loopback: TheaterOptions.loopback(peer), peer: peer) {
                    self.route(request, id: id); return
                }
                if complete || error != nil { self.close(id) } else { self.receive(id, reader: reader) }
            } catch { self.respond(id, 400, "Bad request", Data("Invalid HTTP request.".utf8), type: "text/plain") }
        } }
    }
    private func route(_ request: HTTPRequest, id: UUID) {
        guard access.validHost(request) else { respond(id, 403, "Forbidden", Data()); return }
        let path = request.path
        if request.method == "POST", path == "/api/login" {
            guard access.validMutation(request), let input = try? JSONDecoder().decode(Login.self, from: request.body) else { respond(id, 403, "Forbidden", Data()); return }
            do {
                let token = try access.login(input.passcode, peer: request.peer)
                respond(id, 200, "OK", Data("{}".utf8), headers: ["Set-Cookie": "theater=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=28800"])
            } catch {
                let text = error.localizedDescription
                respondJSON(id, text.contains("Wait") ? 429 : 401, ["error": text])
            }; return
        }
        if request.method == "GET", ["/theater.js", "/theater.css", "/app-icon.png"].contains(path) {
            resource(String(path.dropFirst()), id: id); return
        }
        if request.method == "GET", isPage(path) { resource("index.html", id: id); return }
        guard access.authorized(request) else { respondJSON(id, 401, ["error": "Enter the passcode shown on the Theater host."]); return }
        if request.method == "GET", path == "/api/access" {
            respondJSON(id, 200, ["canManage": request.loopback]); return
        }
        if request.method == "GET", path == "/api/state" {
            respond(id, 200, "OK", (try? controller.json()) ?? Data("{}".utf8)); return
        }
        if request.method == "GET", path == "/events" {
            guard streams.count < 32 else { respondJSON(id, 503, ["error": "Too many open views."]); return }
            guard let connection = connections[id] else { return }
            let head = header(200, "OK", type: "text/event-stream", length: nil)
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in MainActor.assumeIsolated {
                guard let self, error == nil else { self?.close(id); return }
                self.streams[id] = Stream(request: request)
                self.sendStream(id, data: self.event())
                // An EventSource has no request body after its initial GET. Watch for closure.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in MainActor.assumeIsolated { self?.close(id) } }
            } }); return
        }
        if request.method == "GET", path.hasPrefix("/tiles/") { tile(path, id: id); return }
        if request.method == "POST", path == "/api/join" || path == "/api/forget" {
            guard request.loopback, access.validMutation(request) else { respondJSON(id, 403, ["error": "Pairing and disconnecting are available only on the host Mac."]); return }
            do {
                if path == "/api/join" {
                    let input = try JSONDecoder().decode(Join.self, from: request.body)
                    try controller.join(input.invite, name: input.name ?? controller.options.observerName)
                } else {
                    let input = try JSONDecoder().decode(Forget.self, from: request.body)
                    try controller.forget(SquadID(input.squad))
                }
                respondJSON(id, 202, ["ok": true])
            } catch { respondJSON(id, 400, ["error": (error as? TheaterError)?.localizedDescription ?? "Invalid request."]) }
            return
        }
        respond(id, 404, "Not found", Data())
    }
    private struct Login: Decodable { var passcode: String }
    private struct Join: Decodable { var invite: String; var name: String? }
    private struct Forget: Decodable { var squad: UUID }
    private func isPage(_ path: String) -> Bool {
        if path == "/" { return true }
        let parts = path.split(separator: "/")
        return parts.count == 3 && parts[0] == "squads" && UUID(uuidString: String(parts[1])) != nil && ["map", "team", "orders", "notes", "zones", "video", "dashboard", "wall"].contains(String(parts[2]))
    }
    private func resource(_ file: String, id: UUID) {
        guard let url = Bundle.module.url(forResource: file, withExtension: nil, subdirectory: "Web"), let data = try? Data(contentsOf: url) else { respond(id, 404, "Not found", Data()); return }
        let type = file.hasSuffix(".js") ? "text/javascript" : file.hasSuffix(".css") ? "text/css" : file.hasSuffix(".png") ? "image/png" : "text/html"
        respond(id, 200, "OK", data, type: type)
    }
    private func tile(_ path: String, id: UUID) {
        let parts = path.split(separator: "/")
        guard let root = controller.options.tilesDirectory?.resolvingSymlinksInPath(), parts.count == 4,
              let z = Int(parts[1]), (0...controller.options.tileMaxZoom).contains(z), let x = Int(parts[2]),
              parts[3].hasSuffix(".png"), let y = Int(parts[3].dropLast(4)), x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { respond(id, 404, "Not found", Data()); return }
        let file = root.appendingPathComponent("\(z)/\(x)/\(y).png").resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/"), let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), info.isRegularFile == true,
              let size = info.fileSize, size <= 2_000_000, let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { respond(id, 404, "Not found", Data()); return }
        respond(id, 200, "OK", data, type: "image/png", headers: ["Cache-Control": "private, max-age=3600"])
    }
    private func event() -> Data { Data("event: state\ndata: \(String(data: (try? controller.json()) ?? Data("{}".utf8), encoding: .utf8) ?? "{}")\n\n".utf8) }
    public func broadcast() {
        guard !publishing else { return }; publishing = true
        // Coalesce bursts (e.g. replaying notes on join) before encoding a full snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in MainActor.assumeIsolated {
            guard let self else { return }; self.publishing = false; let bytes = self.event()
            for id in Array(self.streams.keys) { self.sendStream(id, data: bytes) }
        } }
    }
    private func sendStream(_ id: UUID, data: Data) {
        guard var stream = streams[id], access.authorized(stream.request), let connection = connections[id] else { close(id); return }
        if stream.sending { stream.pending = data; streams[id] = stream; return }
        stream.sending = true; streams[id] = stream
        connection.send(content: data, completion: .contentProcessed { [weak self] error in MainActor.assumeIsolated {
            guard let self, error == nil, var current = self.streams[id] else { self?.close(id); return }
            current.sending = false; let next = current.pending; current.pending = nil; self.streams[id] = current
            if let next { self.sendStream(id, data: next) }
        } })
    }
    private func respondJSON(_ id: UUID, _ status: Int, _ object: [String: Any]) {
        respond(id, status, status < 400 ? "OK" : "Request failed", (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }
    private func header(_ status: Int, _ reason: String, type: String, length: Int?, extra: [String: String] = [:]) -> String {
        var lines = ["HTTP/1.1 \(status) \(reason)", "Content-Type: \(type)", "Connection: close", "Cache-Control: \(extra["Cache-Control"] ?? "no-store")", "X-Content-Type-Options: nosniff", "Referrer-Policy: no-referrer", "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"]
        if let length { lines.append("Content-Length: \(length)") }
        lines += extra.filter { $0.key != "Cache-Control" }.map { "\($0.key): \($0.value)" }; return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }
    private func respond(_ id: UUID, _ status: Int, _ reason: String, _ data: Data, type: String = "application/json", headers: [String: String] = [:]) {
        guard let connection = connections[id] else { return }
        var bytes = Data(header(status, reason, type: type, length: data.count, extra: headers).utf8); bytes.append(data)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in MainActor.assumeIsolated { self?.close(id) } })
    }
    private func close(_ id: UUID) { streams[id] = nil; connections.removeValue(forKey: id)?.cancel() }
    public func stop() { heartbeat?.cancel(); heartbeat = nil; listeners.forEach { $0.cancel() }; listeners = []; for id in Array(connections.keys) { close(id) } }
}
