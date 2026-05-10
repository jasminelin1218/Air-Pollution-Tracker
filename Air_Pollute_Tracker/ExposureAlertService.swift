import Foundation
import UserNotifications

@MainActor
final class ExposureAlertService {
    static let shared = ExposureAlertService()

    private let lastAlertKey = "lastHighPollutionAlertDate"
    private let cooldownSeconds: TimeInterval = 45 * 60

    private init() {}

    func notifyIfNeeded(pm25: Double) async {
        let threshold = UserDefaults.standard.double(forKey: SettingsKeys.alertThreshold)
            .nonZero(defaultValue: Defaults.alertThreshold)
        guard pm25 >= threshold else {
            return
        }

        let now = Date()
        if let lastAlertDate = UserDefaults.standard.object(forKey: lastAlertKey) as? Date,
           now.timeIntervalSince(lastAlertDate) < cooldownSeconds {
            return
        }

        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "High PM2.5 exposure"
            content.body = "Estimated exposure is \(pm25.formattedPM25), above your \(threshold.formattedPM25) alert threshold."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "high-pm25-\(Int(now.timeIntervalSince1970))",
                content: content,
                trigger: nil
            )
            try await UNUserNotificationCenter.current().add(request)
            UserDefaults.standard.set(now, forKey: lastAlertKey)
        } catch {
            // Notification failure should not interrupt exposure logging.
        }
    }
}

