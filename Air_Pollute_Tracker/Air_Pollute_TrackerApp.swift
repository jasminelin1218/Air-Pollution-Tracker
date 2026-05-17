//
//  Air_Pollute_TrackerApp.swift
//  Air_Pollute_Tracker
//
//  Created by Jasmine Lin on 5/9/26.
//

import BackgroundTasks
import SwiftData
import SwiftUI
import UserNotifications

@main
struct Air_Pollute_TrackerApp: App {
    @StateObject private var tracker = ExposureTracker()

    init() {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationDelegate.shared

        Task {
            try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ExposureTracker.bgRefreshID,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                AppState.shared.tracker?.handleBackgroundRefresh(task: refreshTask)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(sharedTracker: tracker)
                .onAppear { AppState.shared.tracker = tracker }
        }
        .modelContainer(for: ExposureSample.self)
    }
}

/// Dedicated delegate so the UNUserNotificationCenter delegate lifetime is
/// not tied to the SwiftUI App struct lifecycle.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private override init() {}

    /// Show banner + play sound even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

/// Thin bridge so the BGTaskScheduler closure (which runs outside the SwiftUI tree)
/// can reach the shared ExposureTracker without a global variable.
final class AppState {
    static let shared = AppState()
    weak var tracker: ExposureTracker?
    private init() {}
}
