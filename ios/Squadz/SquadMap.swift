import MapKit
import PairKit
import SwiftUI

/// The squad on a MapKit map. When the server has its own map tiles (it may
/// be a mesh node with no internet), they replace Apple's map and are kept
/// on the phone after the first load.
struct SquadMap: UIViewRepresentable {
    let locations: [Located]
    let me: String?
    let tiles: TileSource?
    let client: Client?
    /// Changes when the user asks to see everyone again.
    let recenter: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "member")
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.tiles != tiles {
            c.tiles = tiles
            map.removeOverlays(map.overlays)
            if let tiles, let client {
                map.addOverlay(ServerTileOverlay(source: tiles, client: client), level: .aboveLabels)
            }
        }

        var seen = Set<String>()
        for l in locations {
            seen.insert(l.memberID)
            let pin = c.pins[l.memberID] ?? {
                let pin = MemberPin(id: l.memberID)
                c.pins[l.memberID] = pin
                map.addAnnotation(pin)
                return pin
            }()
            pin.coordinate = CLLocationCoordinate2D(latitude: l.latitude, longitude: l.longitude)
            pin.title = l.name
            pin.isMe = l.memberID == me
            pin.isStale = l.isStale
            if let view = map.view(for: pin) as? MKMarkerAnnotationView { Coordinator.style(view, pin) }
        }
        for (id, pin) in c.pins where !seen.contains(id) {
            map.removeAnnotation(pin)
            c.pins[id] = nil
        }

        // Frame everyone once there is someone to frame, and on request.
        if !c.pins.isEmpty, !c.framed || c.recenter != recenter {
            c.framed = true
            map.showAnnotations(Array(c.pins.values), animated: c.recenter != recenter)
            if c.pins.count == 1, let only = c.pins.values.first {
                map.setRegion(MKCoordinateRegion(center: only.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
            }
        }
        c.recenter = recenter
    }

    final class MemberPin: MKPointAnnotation {
        let id: String
        var isMe = false
        var isStale = false
        init(id: String) { self.id = id }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var pins: [String: MemberPin] = [:]
        var tiles: TileSource?
        var framed = false
        var recenter = 0

        static func style(_ view: MKMarkerAnnotationView, _ pin: MemberPin) {
            view.markerTintColor = pin.isMe ? .systemBlue : .systemGreen
            view.glyphImage = UIImage(systemName: pin.isMe ? "location.fill" : "person.fill")
            view.alpha = pin.isStale ? 0.45 : 1
            view.titleVisibility = .visible
            view.displayPriority = .required
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? MemberPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "member", for: pin) as! MKMarkerAnnotationView
            Self.style(view, pin)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// Map tiles from the squad's server, fetched over the pinned connection and
/// cached on the phone so the map still draws when the link is slow or down.
/// Past the server's deepest zoom level, the deepest tile is scaled up.
final class ServerTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let source: TileSource
    private let client: Client
    private let cache: URL

    /// Where one pairing's tiles are kept; deleted with the pairing.
    static func cacheDirectory(account id: String) -> URL {
        URL.cachesDirectory.appending(path: "tiles/\(id)", directoryHint: .isDirectory)
    }

    init(source: TileSource, client: Client) {
        self.source = source
        self.client = client
        cache = Self.cacheDirectory(account: client.account.id)
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
    }

    private struct Reply: @unchecked Sendable { let call: (Data?, (any Error)?) -> Void }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let reply = Reply(call: result)
        // The tile to fetch: this one, or its ancestor at the deepest level.
        let up = min(max(0, path.z - (source.maxZoom ?? path.z)), 6)
        let (z, x, y) = (path.z - up, path.x >> up, path.y >> up)
        let (subX, subY) = (path.x - (x << up), path.y - (y << up))
        Task.detached(priority: .utility) { [self] in
            do {
                let data = try await tile(z: z, x: x, y: y)
                reply.call(up == 0 ? data : Self.enlarge(data, levels: up, x: subX, y: subY), nil)
            } catch {
                reply.call(nil, error)
            }
        }
    }

    private func tile(z: Int, x: Int, y: Int) async throws -> Data {
        let file = cache.appending(path: "\(z)/\(x)/\(y).png")
        if let data = try? Data(contentsOf: file) { return data }
        let remote = source.path
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
        let data = try await client.data(remote)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Cuts one descendant's square out of a tile and scales it to full size.
    static func enlarge(_ data: Data, levels: Int, x: Int, y: Int) -> Data? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }
        let parts = CGFloat(1 << levels)
        let (w, h) = (CGFloat(image.width) / parts, CGFloat(image.height) / parts)
        guard let piece = image.cropping(to: CGRect(x: CGFloat(x) * w, y: CGFloat(y) * h, width: w, height: h)) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).pngData { context in
            context.cgContext.interpolationQuality = .low
            UIImage(cgImage: piece).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
    }
}
