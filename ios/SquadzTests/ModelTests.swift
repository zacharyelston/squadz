import Foundation
import Testing
import UIKit
@testable import Squadz

@Test func decodesServerAnswers() throws {
    let me = try JSONDecoder().decode(Me.self, from: Data("""
    {"device_id":"d1","name":"Ana","poll_seconds":10,"stale_seconds":300,
     "squad":{"id":"s1","name":"Alpha","leader_id":"d1","members":[{"id":"d1","name":"Ana"}]},
     "tiles":{"path":"tiles/{z}/{x}/{y}.png","attribution":"© OpenStreetMap","max_zoom":15}}
    """.utf8))
    #expect(me.squad?.leaderID == "d1" && me.tiles?.maxZoom == 15)

    let alone = try JSONDecoder().decode(Me.self, from: Data(#"{"device_id":"d1","name":"Ana","squad":null,"poll_seconds":10}"#.utf8))
    #expect(alone.squad == nil && alone.tiles == nil)

    let reply = try JSONDecoder().decode(LocationsReply.self, from: Data("""
    {"squad":{"id":"s1","name":"Alpha","leader_id":"d1","members":[]},
     "locations":[{"member_id":"d1","name":"Ana","latitude":47.6,"longitude":-122.3,"age":4},
                  {"member_id":"d2","name":"Ben","latitude":47.7,"longitude":-122.4,"accuracy":12,"age":400,"stale":true}]}
    """.utf8))
    #expect(!reply.locations[0].isStale && reply.locations[1].isStale)
}

@Test func positionReportLeavesOutUnknowns() throws {
    let json = String(decoding: try JSONEncoder().encode(PositionReport(latitude: 1, longitude: 2)), as: UTF8.self)
    #expect(!json.contains("altitude") && !json.contains("speed"))
}

@Test func memberStatusText() {
    func located(age: Int, stale: Bool) -> Located {
        try! JSONDecoder().decode(Located.self, from: Data(#"{"member_id":"d","name":"n","latitude":0,"longitude":0,"age":\#(age),"stale":\#(stale)}"#.utf8))
    }
    #expect(MemberList.status(nil) == "No position yet")
    #expect(MemberList.status(located(age: 5, stale: false)) == "Now")
    #expect(MemberList.status(located(age: 400, stale: true)) == "6 min ago")
    #expect(MemberList.status(located(age: 7300, stale: true)) == "2 h ago")
}

@MainActor @Test func inviteLinkRoundTrip() throws {
    let code = #"{"v":1,"app":"squadz","server":"10.41.253.10:8443","key_pin":"7ZMAdPTP+EYlXMeajUDBC9WNvLnq4heWzOt/XGrxgG8=","invite":"AAAAAAAAAAAAAAAAAAAAAA"}"#
    let link = try #require(AppModel.link(for: code))
    let value = link.absoluteString.dropFirst("squadz://pair?c=".count)
    #expect(link.absoluteString.hasPrefix("squadz://pair?c=") && !value.contains("+") && !value.contains("/") && !value.contains("="))
    #expect(AppModel.code(from: link) == code)
    #expect(AppModel.code(from: URL(string: "squadz://other?c=abc")!) == nil)
    #expect(AppModel.code(from: URL(string: "https://example.com/pair?c=abc")!) == nil)
}

@Test func enlargesOneQuarterOfATile() throws {
    // A 256pt tile: left half red, right half blue.
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let tile = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { c in
        UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 128, height: 256))
        UIColor.blue.setFill(); c.fill(CGRect(x: 128, y: 0, width: 128, height: 256))
    }
    func centre(_ data: Data?) throws -> [UInt8] {
        let image = try #require(data.flatMap(UIImage.init(data:))?.cgImage)
        #expect(image.width == 256 && image.height == 256)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -128, y: -128, width: 256, height: 256))
        return pixel
    }
    let left = try centre(ServerTileOverlay.enlarge(tile, levels: 1, x: 0, y: 1))
    let right = try centre(ServerTileOverlay.enlarge(tile, levels: 1, x: 1, y: 0))
    #expect(left[0] > 200 && left[2] < 50)
    #expect(right[2] > 200 && right[0] < 50)
}
