import CoreLocation
import Observation

/// Which way this device is pointing, from its compass, while the app is open. Nil on a device
/// with no compass, and until the first reading.
@MainActor
@Observable
final class Compass: NSObject, CLLocationManagerDelegate {
    /// Degrees clockwise from true north, or from magnetic north where true north isn't known.
    private(set) var heading: Double?
    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // A reading for every few degrees of turn is plenty for an arrow on a map.
        manager.headingFilter = 4
    }

    func start() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
        heading = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading new: CLHeading) {
        // Negative means the compass doesn't trust itself right now.
        guard new.headingAccuracy >= 0 else { return }
        let degrees = new.trueHeading >= 0 ? new.trueHeading : new.magneticHeading
        Task { @MainActor in self.heading = degrees }
    }

    /// Let iOS ask the person to wave the phone about when the compass needs it.
    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}
