import CoreGeo
import MapKit
import SquadKit
import SwiftUI

/// The squad on a MapKit map. The map itself is Apple's, which needs the internet for places
/// the phone hasn't looked at before; the pins don't.
struct SquadMap: UIViewRepresentable {
    let located: [Located]
    let now: Date
    /// Changes when the user asks to see everyone again.
    let recenter: Int
    /// Which way this device points, to turn its own arrow. Nil without a compass.
    var heading: Double?
    /// Places to mark: orders that are still open, and the one being written.
    var places: [Place] = []
    /// While set, a tap on the map picks a place instead of doing what a tap usually does.
    var onPick: ((GeoPoint) -> Void)?

    /// A marked place on the map.
    struct Place: Identifiable, Equatable {
        var id: UUID
        var title: String
        var at: GeoPoint
        /// Still being written: shown in another colour.
        var isDraft = false
        var color: UIColor = .systemOrange
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "member")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "place")
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.onPick = onPick
        c.heading = heading
        var marked = Set<UUID>()
        for place in places {
            marked.insert(place.id)
            let pin = c.places[place.id] ?? {
                let pin = PlacePin(id: place.id)
                c.places[place.id] = pin
                map.addAnnotation(pin)
                return pin
            }()
            pin.coordinate = CLLocationCoordinate2D(latitude: place.at.latitude, longitude: place.at.longitude)
            pin.title = place.title
            pin.isDraft = place.isDraft
            pin.color = place.color
            if let view = map.view(for: pin) as? MKMarkerAnnotationView { Coordinator.style(view, pin) }
        }
        for (id, pin) in c.places where !marked.contains(id) {
            map.removeAnnotation(pin)
            c.places[id] = nil
        }
        // A flag that has just been put down somewhere the map isn't showing: zoom out to it.
        let flags = Set(places.filter { !$0.isDraft }.map(\.id))
        let outOfView = flags.subtracting(c.flagsShown).contains { id in
            c.places[id].map { !map.visibleMapRect.contains(MKMapPoint($0.coordinate)) } ?? false
        }
        c.flagsShown = flags
        var seen = Set<MemberID>()
        for l in located {
            guard let position = l.position else { continue }
            seen.insert(l.id)
            let pin = c.pins[l.id] ?? {
                let pin = MemberPin(id: l.id)
                c.pins[l.id] = pin
                map.addAnnotation(pin)
                return pin
            }()
            pin.coordinate = CLLocationCoordinate2D(latitude: position.at.latitude, longitude: position.at.longitude)
            pin.title = l.member.name
            pin.isMe = l.isMe
            pin.isStale = l.isStale(now: now)
            if let view = map.view(for: pin) as? MKMarkerAnnotationView { c.style(view, pin, on: map) }
        }
        for (id, pin) in c.pins where !seen.contains(id) {
            map.removeAnnotation(pin)
            c.pins[id] = nil
        }

        // Frame everyone when someone new shows up, and on request.
        let everything = c.pins.values.map(\.coordinate) + c.places.values.filter { !$0.isDraft }.map(\.coordinate)
        if !everything.isEmpty, c.framed != c.pins.count || c.recenter != recenter || outOfView {
            let asked = c.recenter != recenter || outOfView
            c.framed = c.pins.count
            if everything.count == 1, let only = everything.first {
                map.setRegion(MKCoordinateRegion(center: only, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: asked)
            } else {
                // Room around the outermost pins and flags for their markers and names.
                let rect = everything.reduce(MKMapRect.null) {
                    $0.union(MKMapRect(origin: MKMapPoint($1), size: MKMapSize(width: 0, height: 0)))
                }
                map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 60, right: 60), animated: asked)
            }
        }
        c.recenter = recenter
    }

    final class MemberPin: MKPointAnnotation {
        let id: MemberID
        var isMe = false
        var isStale = false
        init(id: MemberID) { self.id = id }
    }

    final class PlacePin: MKPointAnnotation {
        let id: UUID
        var isDraft = false
        var color: UIColor = .systemOrange
        init(id: UUID) { self.id = id }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var pins: [MemberID: MemberPin] = [:]
        var places: [UUID: PlacePin] = [:]
        /// The orders' flags on the map at the last update, to tell a new one.
        var flagsShown: Set<UUID> = []
        var onPick: ((GeoPoint) -> Void)?

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let onPick, let map = tap.view as? MKMapView, tap.state == .ended else { return }
            let c = map.convert(tap.location(in: map), toCoordinateFrom: map)
            onPick(GeoPoint(latitude: c.latitude, longitude: c.longitude))
        }

        static func style(_ view: MKMarkerAnnotationView, _ pin: PlacePin) {
            view.markerTintColor = pin.isDraft ? .systemPurple : pin.color
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.titleVisibility = .visible
            view.displayPriority = .required
        }

        /// How many pins were on the map when it was last framed.
        var framed = 0
        var recenter = 0

        var heading: Double?
        /// The arrow as last drawn, so it is drawn again only when it has turned.
        private var arrowDrawn: (degrees: Int, image: UIImage)?

        /// This device's pin is an arrow that points the way the device does, whichever way up
        /// the map is. Without a compass it is the plain location mark.
        func style(_ view: MKMarkerAnnotationView, _ pin: MemberPin, on map: MKMapView) {
            view.markerTintColor = pin.isMe ? .systemBlue : .systemGreen
            if pin.isMe, let heading {
                let degrees = Int((heading - map.camera.heading).rounded())
                if arrowDrawn?.degrees != degrees, let arrow = Self.arrow(turned: Double(degrees)) {
                    arrowDrawn = (degrees, arrow)
                }
                if view.glyphImage !== arrowDrawn?.image { view.glyphImage = arrowDrawn?.image }
            } else {
                view.glyphImage = UIImage(systemName: pin.isMe ? "location.fill" : "person.fill")
            }
            view.alpha = pin.isStale ? 0.45 : 1
            view.titleVisibility = .visible
            view.displayPriority = .required
        }

        /// An arrow pointing up, turned clockwise by `degrees`.
        static func arrow(turned degrees: Double) -> UIImage? {
            guard let up = UIImage(systemName: "location.north.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)) else { return nil }
            let side = max(up.size.width, up.size.height) * 1.3
            let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
                context.cgContext.translateBy(x: side / 2, y: side / 2)
                context.cgContext.rotate(by: degrees * .pi / 180)
                up.draw(at: CGPoint(x: -up.size.width / 2, y: -up.size.height / 2))
            }
            return image.withRenderingMode(.alwaysTemplate)
        }

        /// The map was turned: the arrow has to turn against it.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            guard heading != nil, let mine = pins.values.first(where: \.isMe),
                  let view = mapView.view(for: mine) as? MKMarkerAnnotationView else { return }
            style(view, mine, on: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let place = annotation as? PlacePin {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "place", for: place) as! MKMarkerAnnotationView
                Self.style(view, place)
                return view
            }
            guard let pin = annotation as? MemberPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "member", for: pin) as! MKMarkerAnnotationView
            style(view, pin, on: mapView)
            return view
        }
    }
}
