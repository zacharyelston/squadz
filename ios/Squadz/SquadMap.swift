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
            if let view = map.view(for: pin) as? MKMarkerAnnotationView { Coordinator.style(view, pin) }
        }
        for (id, pin) in c.places where !marked.contains(id) {
            map.removeAnnotation(pin)
            c.places[id] = nil
        }
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
            if let view = map.view(for: pin) as? MKMarkerAnnotationView { Coordinator.style(view, pin) }
        }
        for (id, pin) in c.pins where !seen.contains(id) {
            map.removeAnnotation(pin)
            c.pins[id] = nil
        }

        // Frame everyone when someone new shows up, and on request.
        if !c.pins.isEmpty, c.framed != c.pins.count || c.recenter != recenter {
            let asked = c.recenter != recenter
            c.framed = c.pins.count
            if c.pins.count == 1, let only = c.pins.values.first {
                map.setRegion(MKCoordinateRegion(center: only.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: asked)
            } else {
                // Room around the outermost pins for their markers and names.
                let rect = c.pins.values.reduce(MKMapRect.null) {
                    $0.union(MKMapRect(origin: MKMapPoint($1.coordinate), size: MKMapSize(width: 0, height: 0)))
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
        init(id: UUID) { self.id = id }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var pins: [MemberID: MemberPin] = [:]
        var places: [UUID: PlacePin] = [:]
        var onPick: ((GeoPoint) -> Void)?

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let onPick, let map = tap.view as? MKMapView, tap.state == .ended else { return }
            let c = map.convert(tap.location(in: map), toCoordinateFrom: map)
            onPick(GeoPoint(latitude: c.latitude, longitude: c.longitude))
        }

        static func style(_ view: MKMarkerAnnotationView, _ pin: PlacePin) {
            view.markerTintColor = pin.isDraft ? .systemPurple : .systemOrange
            view.glyphImage = UIImage(systemName: "flag.fill")
            view.titleVisibility = .visible
            view.displayPriority = .required
        }

        /// How many pins were on the map when it was last framed.
        var framed = 0
        var recenter = 0

        static func style(_ view: MKMarkerAnnotationView, _ pin: MemberPin) {
            view.markerTintColor = pin.isMe ? .systemBlue : .systemGreen
            view.glyphImage = UIImage(systemName: pin.isMe ? "location.fill" : "person.fill")
            view.alpha = pin.isStale ? 0.45 : 1
            view.titleVisibility = .visible
            view.displayPriority = .required
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if let place = annotation as? PlacePin {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "place", for: place) as! MKMarkerAnnotationView
                Self.style(view, place)
                return view
            }
            guard let pin = annotation as? MemberPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "member", for: pin) as! MKMarkerAnnotationView
            Self.style(view, pin)
            return view
        }
    }
}
