import Foundation
import SquadKit
import UserNotifications

/// System banners supplement the in-app zone banner. Permission is requested only by a tap.
final class ZoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ZoneNotifications()
    private override init() { super.init() }

    func enable() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func post(_ event: ZoneEvent) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = event.kind == .arrived ? "Goal reached" : "Left allowed area"
            content.body = event.text
            content.sound = .default
            let request = UNNotificationRequest(identifier: "zone-\(event.id)", content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
