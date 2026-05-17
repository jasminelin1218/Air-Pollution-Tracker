import BackgroundTasks
import Combine
import CoreLocation
import Foundation
import SwiftData

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

    // Two-phase timer: delayTimer fires once after the remaining wait, then repeatTimer takes over.
    private var delayTimer: Timer?
    private var repeatTimer: Timer?
    // Observes UserDefaults so the timer reschedules live when the interval setting changes.
    private var intervalCancellable: AnyCancellable?

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
        locationManager.distanceFilter = Defaults.minimumDistanceMeters
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
        locationManager.distanceFilter = Defaults.minimumDistanceMeters
        startSampleTimer()
        isTracking = true
        statusMessage = "Tracking (foreground only — grant Always permission for background)."
    }

    // MARK: - Core sampling

    private func process(location: CLLocation, forced: Bool = false) async {
        guard forced || shouldSample() else { return }
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
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Sampling failed — will retry on next location update."
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
        scheduleTimerFromLastSample()

        // Re-arm automatically whenever the interval setting changes while tracking.
        intervalCancellable = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isTracking else { return }
                let newInterval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
                    .nonZero(defaultValue: Defaults.sampleIntervalSeconds)
                let currentInterval = self.repeatTimer?.timeInterval ?? 0
                guard abs(currentInterval - newInterval) > 0.5 else { return }
                self.scheduleTimerFromLastSample()
                self.scheduleBackgroundRefresh()
            }
    }

    /// Computes how long until the next sample is due (based on last sample time) and
    /// fires a one-shot timer for that remaining delay, then switches to a repeating timer.
    private func scheduleTimerFromLastSample() {
        delayTimer?.invalidate(); delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil

        let interval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
            .nonZero(defaultValue: Defaults.sampleIntervalSeconds)
        let elapsed = lastSampleDate.map { Date().timeIntervalSince($0) } ?? interval
        let delay = max(0, interval - elapsed)

        if delay < 1 {
            // Already overdue — defer by one runloop cycle to ensure modelContext is set,
            // then sample and start the repeating cycle.
            let t = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.delayTimer = nil
                    self.requestOneShotLocation(forced: false)
                    self.startRepeatTimer(interval: interval)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            delayTimer = t
        } else {
            // Wait out the remaining portion of the current interval.
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.delayTimer = nil
                    self.requestOneShotLocation(forced: false)
                    let nextInterval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
                        .nonZero(defaultValue: Defaults.sampleIntervalSeconds)
                    self.startRepeatTimer(interval: nextInterval)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            delayTimer = t
        }
    }

    private func startRepeatTimer(interval: TimeInterval) {
        repeatTimer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestOneShotLocation(forced: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        repeatTimer = t
    }

    private func stopSampleTimer() {
        delayTimer?.invalidate(); delayTimer = nil
        repeatTimer?.invalidate(); repeatTimer = nil
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
                await process(location: location, forced: true)
                task.setTaskCompleted(success: true)
            }
        } else {
            // No cached location — request a one-shot precise fix
            pendingBGTask = task
            requestOneShotLocation(forced: true)
        }
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


