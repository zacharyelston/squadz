import CoreGeo
import CoreLocation
import SquadKit

/// Follows this phone's position while the app is open.
@MainActor
final class LocationTracker {
    private let manager = CLLocationManager()
    private var task: Task<Void, Never>?
    private var fix: CLLocation?
    /// Whether Core Location still stands by `fix`. A phone that isn't moving gets no new fixes,
    /// and its last one is still where it is; a phone that has lost its position is told so.
    private var current = false

    /// Where this phone is, as of `now` while Core Location stands by its last fix, and as of
    /// that fix's own time once it doesn't.
    func latest(now: Date = .now) -> MemberPosition? {
        guard let fix, var position = MemberPosition(fix) else { return nil }
        if current { position.time = max(position.time, now) }
        return position
    }

    func start() {
        guard task == nil else { return }
        manager.requestWhenInUseAuthorization()
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location {
                        self?.fix = location
                        self?.current = true
                    } else {
                        self?.current = false
                    }
                }
            } catch {}
            self?.current = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        fix = nil
        current = false
    }
}

extension MemberPosition {
    /// Core Location marks "unknown" with negative numbers: a fix with no accuracy is dropped,
    /// and so is a heading it doesn't know.
    init?(_ l: CLLocation) {
        guard l.horizontalAccuracy >= 0 else { return nil }
        self.init(at: GeoPoint(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
                  accuracy: l.horizontalAccuracy.rounded(), heading: l.course >= 0 ? l.course.rounded() : nil,
                  time: l.timestamp)
    }
}
