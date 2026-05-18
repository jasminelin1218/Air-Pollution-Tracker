import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import SwiftData
import UIKit

// MARK: - Background task identifier
extension ExposureTracker {
    static let bgRefreshID = "edu.ucsd.Air-Pollute-Tracker.refresh"
}

@MainActor
final class ExposureTracker: NSObject, ObservableObject {
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var isTracking = false
    @Published var isSampling = false
    @Published var lastSample: ExposureSample?
    @Published var statusMessage = "Ready to track exposure."
    @Published var errorMessage: String?

    private let locationManager = CLLocationManager()
    private var modelContext: ModelContext?
    private var lastSampleDate: Date?

    // Single chained sample timer.
    private var sampleTimer: Timer?
    // Observes UserDefaults so the timer reschedules live when the interval setting changes.
    private var intervalCancellable: AnyCancellable?
    // Prevents concurrent process() calls from producing duplicate samples.
    private var isProcessingSample = false

    // Set true when we want the next didUpdateLocations to be treated as a one-shot precise fix
    private var pendingPreciseFix = false
    private var pendingPreciseFixIsForced = false
    // Held while a BGAppRefreshTask is in flight so the delegate can close it
    private var pendingBGTask: BGTask?

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.activityType = .other
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        pruneOldSamples()
    }

    // MARK: - Public control

    func startTracking() {
        errorMessage = nil
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways:
            beginTracking()
        case .authorizedWhenInUse:
            statusMessage = "Grant 'Always' location access in Settings for background tracking."
            errorMessage = "Change location permission to 'Always' in Settings → Privacy → Location Services."
            beginForegroundOnly()
        case .denied, .restricted:
            statusMessage = "Location permission is required for exposure tracking."
            errorMessage = "Enable location access in Settings to start tracking."
        @unknown default:
            statusMessage = "Unknown location permission state."
        }
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        stopSampleTimer()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ExposureTracker.bgRefreshID)
        isTracking = false
        statusMessage = "Tracking paused."
    }

    func sampleCurrentLocationNow() {
        if let location = locationManager.location {
            Task { await process(location: location, forced: true) }
        } else {
            statusMessage = "Waiting for a location fix..."
            requestOneShotLocation(forced: true)
        }
    }

    // MARK: - Internal start modes

    /// Full background mode: significant-change (primary, near-zero battery) +
    /// periodic one-shot location requests + BGAppRefreshTask fallback.
    private func beginTracking() {
        guard CLLocationManager.locationServicesEnabled() else {
            statusMessage = "Location services are off."
            return
        }
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        #endif
        // Significant-change monitoring: resumes even after app termination (iOS re-launches the app).
        // Fires roughly when the device moves ~500 m or switches cell tower — ideal for our use case.
        locationManager.startMonitoringSignificantLocationChanges()
        // Low-accuracy continuous updates wake the app in the background even when stationary,
        // bridging gaps between significant-location events and BGAppRefreshTask deliveries.
        // kCLLocationAccuracyThreeKilometers is sufficient for a 10 km OpenAQ search radius
        // while minimising battery use; didUpdateLocations is gated by shouldSample() so
        // OpenAQ is not called on every small jitter.
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.startUpdatingLocation()
        startSampleTimer()

        isTracking = true
        statusMessage = "Tracking (low-power periodic sampling active)."
        scheduleBackgroundRefresh()
    }

    /// Foreground-only fallback when the user grants only "When in Use".
    private func beginForegroundOnly() {
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = false
        #endif
        locationManager.stopUpdatingLocation()
        locationManager.distanceFilter = Defaults.minimumDistanceMeters
        startSampleTimer()
        isTracking = true
        statusMessage = "Tracking (foreground only — grant Always permission for background)."
    }

    // MARK: - Core sampling

    private func process(location: CLLocation, forced: Bool = false) async {
        guard forced || shouldSample() else { return }
        guard !isProcessingSample else { return }
        isProcessingSample = true
        defer { isProcessingSample = false }
        guard let modelContext else {
            errorMessage = "Storage is not ready yet — will retry on next sample."
            // Retry once after a short delay to handle the race between
            // startTracking() and .onAppear setting the modelContext.
            try? await Task.sleep(for: .seconds(2))
            if modelContext != nil {
                await process(location: location, forced: forced)
            }
            return
        }

        isSampling = true
        statusMessage = "Fetching nearby PM2.5 readings..."
        errorMessage = nil

        do {
            let apiKey = Self.currentAPIKey()
            let readings = try await OpenAQClient(apiKey: apiKey).fetchPM25Readings(
                near: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                radiusMeters: Defaults.searchRadiusMeters
            )
            let result = try IDWInterpolator.interpolate(
                at: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                readings: readings,
                nearestCount: min(5, max(3, readings.count))
            )

            let sample = ExposureSample(
                timestamp: Date(),
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                pm25: result.pm25,
                stationCount: result.usedReadings.count,
                sourceSummary: result.usedReadings.map(\.name).joined(separator: ", ")
            )
            modelContext.insert(sample)
            try modelContext.save()

            lastSample = sample
            lastSampleDate = sample.timestamp
            let nearestKm = result.usedReadings
                .compactMap(\.distanceMeters)
                .min()
                .map { String(format: "nearest %.1f km", $0 / 1000) }
                ?? "distance unknown"
            statusMessage = "Latest: \(sample.pm25.formattedPM25) · \(sample.stationCount) station(s), \(nearestKm) · \(sample.timestamp.shortTimeString)"
            pruneOldSamples()
            await ExposureAlertService.shared.notifyIfNeeded(pm25: sample.pm25)
            if isTracking { scheduleNextSample() }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Sampling failed — will retry on next location update."
            if isTracking { scheduleNextSample() }
        }

        isSampling = false
        scheduleBackgroundRefresh()
    }

    private func shouldSample() -> Bool {
        let interval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
            .nonZero(defaultValue: Defaults.sampleIntervalSeconds)
        if let lastSampleDate, Date().timeIntervalSince(lastSampleDate) < interval {
            return false
        }
        return true
    }

    private func startSampleTimer() {
        stopSampleTimer()
        scheduleNextSample()

        // Re-arm automatically whenever the interval setting changes while tracking.
        intervalCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isTracking else { return }
                self.scheduleNextSample()
                self.scheduleBackgroundRefresh()
            }
    }

    /// Schedules one non-repeating timer that fires when the next sample is due,
    /// computed from lastSampleDate. Called again after each successful sample.
    func scheduleNextSample() {
        sampleTimer?.invalidate()
        sampleTimer = nil

        let interval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
            .nonZero(defaultValue: Defaults.sampleIntervalSeconds)
        let elapsed = lastSampleDate.map { Date().timeIntervalSince($0) } ?? interval
        // At least 0.5 s to ensure modelContext is set before the first sample fires.
        let delay = max(0.5, interval - elapsed)

        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.sampleTimer = nil
                self?.requestOneShotLocation(forced: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sampleTimer = t
    }

    private func stopSampleTimer() {
        sampleTimer?.invalidate()
        sampleTimer = nil
        intervalCancellable = nil
    }

    private func requestOneShotLocation(forced: Bool) {
        pendingPreciseFix = true
        pendingPreciseFixIsForced = forced
        locationManager.requestLocation()
    }

    // MARK: - BGAppRefreshTask (time-based fallback when the user is stationary)

    func scheduleBackgroundRefresh() {
        let interval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
            .nonZero(defaultValue: Defaults.sampleIntervalSeconds)
        let request = BGAppRefreshTaskRequest(identifier: ExposureTracker.bgRefreshID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // Re-arm immediately so the chain never breaks
        task.expirationHandler = {
            self.pendingBGTask = nil
            task.setTaskCompleted(success: false)
        }

        if let location = locationManager.location {
            Task {
                await process(location: location, forced: false)
                task.setTaskCompleted(success: true)
            }
        } else {
            // No cached location — request a one-shot precise fix
            pendingBGTask = task
            requestOneShotLocation(forced: false)
        }
    }

    // MARK: - Scene-phase lifecycle hooks

    /// Called when the app enters the background (scene phase observer).
    /// Schedules a BG refresh and uses a short UIKit background task to attempt
    /// one final sample before the process is suspended.
    func appDidEnterBackground() {
        guard isTracking else { return }
        scheduleBackgroundRefresh()
        var bgTaskID = UIBackgroundTaskIdentifier.invalid
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "AirPollute.catchUpSample") {
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }
        guard bgTaskID != .invalid else { return }
        Task {
            if let location = locationManager.location {
                await process(location: location, forced: false)
            }
            UIApplication.shared.endBackgroundTask(bgTaskID)
        }
    }

    /// Called when the app returns to the foreground (scene phase observer).
    /// Re-arms the sample timer so it fires on schedule or immediately if overdue.
    func appWillEnterForeground() {
        guard isTracking else { return }
        scheduleNextSample()
    }

    // MARK: - Pruning & helpers

    private func pruneOldSamples() {
        guard let modelContext else { return }
        let rawDuration = UserDefaults.standard.object(forKey: SettingsKeys.trackingDays) as? Int
            ?? TrackingDuration.sevenDays.rawValue
        let duration = TrackingDuration(rawValue: rawDuration) ?? .sevenDays
        let cutoff = Date().addingTimeInterval(-duration.windowInterval)
        let descriptor = FetchDescriptor<ExposureSample>(
            predicate: #Predicate { sample in
                sample.timestamp < cutoff
            }
        )
        if let oldSamples = try? modelContext.fetch(descriptor), !oldSamples.isEmpty {
            oldSamples.forEach(modelContext.delete)
            try? modelContext.save()
        }
    }

    private static func currentAPIKey() -> String {
        let stored = UserDefaults.standard.string(forKey: SettingsKeys.openAQAPIKey) ?? ""
        if !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored
        }
        return Bundle.main.object(forInfoDictionaryKey: "OPENAQAPIKey") as? String ?? ""
    }
}

// MARK: - CLLocationManagerDelegate

extension ExposureTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways {
                beginTracking()
            } else if manager.authorizationStatus == .authorizedWhenInUse {
                beginForegroundOnly()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            if pendingPreciseFix {
                let forced = pendingPreciseFixIsForced
                pendingPreciseFix = false
                pendingPreciseFixIsForced = false
                await process(location: location, forced: forced)
                pendingBGTask?.setTaskCompleted(success: true)
                pendingBGTask = nil
            } else {
                await process(location: location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            pendingPreciseFix = false
            pendingPreciseFixIsForced = false
            pendingBGTask?.setTaskCompleted(success: false)
            pendingBGTask = nil
            errorMessage = error.localizedDescription
            statusMessage = "Location update failed."
        }
    }
}


