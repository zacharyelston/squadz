import Foundation
import XCTest
@testable import TheaterKit

final class TheaterTests: XCTestCase {
    func testRequestReaderRejectsAmbiguousFraming() throws {
        for text in ["POST /api/join HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n", "POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n", "GET //evil.test/ HTTP/1.1\r\nHost: localhost\r\n\r\n"] {
            var reader = HTTPReader()
            XCTAssertThrowsError(try reader.append(Data(text.utf8), loopback: true, peer: "127.0.0.1"))
        }
    }
}

extension TheaterTests {
    func testFragmentedBodyAndSizeLimits() throws {
        var reader = HTTPReader()
        XCTAssertNil(try reader.append(Data("POST /api/join HTTP/1.1\r\nHost: localhost:8765\r\nContent-Length: 2\r\n\r\n{".utf8), loopback: true, peer: "127.0.0.1"))
        let parsed = try XCTUnwrap(reader.append(Data("}".utf8), loopback: true, peer: "127.0.0.1"))
        XCTAssertEqual(parsed.path, "/api/join"); XCTAssertEqual(parsed.body, Data("{}".utf8))
        var large = HTTPReader()
        XCTAssertThrowsError(try large.append(Data(repeating: 65, count: 33_000), loopback: true, peer: "127.0.0.1"))
    }
    func testOnlyExplicitLocalBindings() throws {
        for host in ["0.0.0.0", "::", "8.8.8.8", "example.org"] {
            var options = TheaterOptions(); options.bind = host
            XCTAssertThrowsError(try options.validate())
        }
        for host in ["127.0.0.1", "::1", "10.1.2.3", "192.168.5.10", "172.16.0.2"] {
            var options = TheaterOptions(); options.bind = host; XCTAssertNoThrow(try options.validate())
        }
    }
    @MainActor func testLANPasscodeSessionsOriginsAndHostValidation() throws {
        let access = HTTPAccess(bind: "192.168.1.10", port: 8765, passcode: "sample-passcode")
        var request = HTTPRequest(method: "POST", path: "/api/login", headers: ["host":"192.168.1.10:8765", "origin":"http://192.168.1.10:8765", "content-type":"application/json", "x-theater-request":"1"], body: Data(), loopback: false, peer: "192.168.1.20")
        XCTAssertTrue(access.validHost(request)); XCTAssertTrue(access.validMutation(request)); XCTAssertFalse(access.authorized(request))
        XCTAssertThrowsError(try access.login("wrong", peer: request.peer))
        let now = Date.now, token = try access.login("sample-passcode", peer: request.peer, now: now)
        request.headers["cookie"] = "theater=" + token
        XCTAssertTrue(access.authorized(request, now: now)); XCTAssertFalse(access.authorized(request, now: now.addingTimeInterval(9*3600)))
        request.headers["origin"] = "https://evil.example"
        XCTAssertFalse(access.validMutation(request))
        request.headers["host"] = "evil.example:8765"
        XCTAssertFalse(access.validHost(request))
        for _ in 0..<8 { _ = try? access.login("bad", peer: "another") }
        XCTAssertThrowsError(try access.login("sample-passcode", peer: "another"))
    }
}
