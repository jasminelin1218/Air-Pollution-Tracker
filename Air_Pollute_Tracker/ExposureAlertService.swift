import Foundation
import UserNotifications

@MainActor
final class ExposureAlertService {
    static let shared = ExposureAlertService()

    private let lastAlertKey = "lastHighPollutionAlertDate"
    private let cooldownSeconds: TimeInterval = 45 * 60

    func resetCooldown() {
        UserDefaults.standard.removeObject(forKey: lastAlertKey)
    }

    func notifyIfNeeded(pm25: Double) async {
        let threshold = UserDefaults.standard.double(forKey: SettingsKeys.alertThreshold)
            .nonZero(defaultValue: Defaults.alertThreshold)
        guard pm25.rounded(toPlaces: 1) >= threshold.rounded(toPlaces: 1) else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let now = Date()
        if let lastAlertDate = UserDefaults.standard.object(forKey: lastAlertKey) as? Date,
           now.timeIntervalSince(lastAlertDate) < cooldownSeconds {
            return
        }

        do {
            let content = UNMutableNotificationContent()
            content.title = "High PM2.5 Exposure"
            content.body = "Estimated exposure is \(pm25.formattedPM25), above your \(threshold.formattedPM25) alert threshold."
            content.interruptionLevel = .timeSensitive

            // Use bundled double-ding; fall back to the system default if the file is absent.
            let soundName = UNNotificationSoundName("ding_ding.caf")
            let bundleURL = Bundle.main.url(forResource: "ding_ding", withExtension: "caf")
            content.sound = bundleURL != nil
                ? UNNotificationSound(named: soundName)
                : .default

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

