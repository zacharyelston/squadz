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

    final class Coordinator: NSObject, MKMapViewDelegate {
        var pins: [MemberID: MemberPin] = [:]
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
            guard let pin = annotation as? MemberPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "member", for: pin) as! MKMarkerAnnotationView
            Self.style(view, pin)
            return view
        }
    }
}
