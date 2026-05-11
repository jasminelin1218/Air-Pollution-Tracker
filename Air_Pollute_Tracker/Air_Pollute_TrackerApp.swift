//
//  Air_Pollute_TrackerApp.swift
//  Air_Pollute_Tracker
//
//  Created by Jasmine Lin on 5/9/26.
//

import BackgroundTasks
import SwiftData
import SwiftUI

@main
struct Air_Pollute_TrackerApp: App {
    @StateObject private var tracker = ExposureTracker()

    init() {
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

/// Thin bridge so the BGTaskScheduler closure (which runs outside the SwiftUI tree)
/// can reach the shared ExposureTracker without a global variable.
final class AppState {
    static let shared = AppState()
    weak var tracker: ExposureTracker?
    private init() {}
}
