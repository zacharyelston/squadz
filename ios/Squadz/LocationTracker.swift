import CoreLocation

/// Follows this phone's position while the app is open.
@MainActor
final class LocationTracker {
    private let manager = CLLocationManager()
    private var task: Task<Void, Never>?
    private(set) var latest: PositionReport?

    func start() {
        guard task == nil else { return }
        manager.requestWhenInUseAuthorization()
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let location = update.location else { continue }
                    self?.latest = PositionReport(location)
                }
            } catch {}
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        latest = nil
    }
}

extension PositionReport {
    /// Core Location marks "unknown" with negative numbers; those are dropped.
    init(_ l: CLLocation) {
        self.init(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                  altitude: l.verticalAccuracy >= 0 ? (l.altitude * 10).rounded() / 10 : nil,
                  accuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy.rounded() : nil,
                  heading: l.course >= 0 ? l.course.rounded() : nil,
                  speed: l.speed >= 0 ? (l.speed * 10).rounded() / 10 : nil)
    }
}
