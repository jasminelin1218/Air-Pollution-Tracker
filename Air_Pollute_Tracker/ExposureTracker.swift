import Combine
import CoreLocation
import Foundation
import SwiftData

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
    private var lastSampleLocation: CLLocation?

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = Defaults.minimumDistanceMeters
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.activityType = .fitness
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        pruneOldSamples()
    }

    func startTracking() {
        errorMessage = nil

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationUpdates()
        case .denied, .restricted:
            statusMessage = "Location permission is required for exposure tracking."
            errorMessage = "Enable location access in Settings to start tracking."
        @unknown default:
            statusMessage = "Unknown location permission state."
        }
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        isTracking = false
        statusMessage = "Tracking paused."
    }

    func sampleCurrentLocationNow() {
        guard let location = locationManager.location else {
            statusMessage = "Waiting for a location fix."
            locationManager.requestLocation()
            return
        }

        Task {
            await process(location: location, forced: true)
        }
    }

    private func beginLocationUpdates() {
        if CLLocationManager.locationServicesEnabled() {
            #if os(iOS)
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
            #endif
            locationManager.startUpdatingLocation()
            isTracking = true
            statusMessage = "Tracking location for exposure samples."
        } else {
            statusMessage = "Location services are off."
        }
    }

    private func process(location: CLLocation, forced: Bool = false) async {
        guard shouldSample(location: location, forced: forced) else {
            return
        }

        guard let modelContext else {
            errorMessage = "Storage is not ready yet."
            return
        }

        isSampling = true
        statusMessage = "Fetching nearby PM2.5 readings..."
        errorMessage = nil

        do {
            let apiKey = Self.currentAPIKey()
            let readings = try await OpenAQClient(apiKey: apiKey).fetchPM25Readings(
                near: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
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
            lastSampleLocation = location
            statusMessage = "Latest exposure: \(sample.pm25.formattedPM25) PM2.5 from \(sample.stationCount) station(s)."
            pruneOldSamples()
            await ExposureAlertService.shared.notifyIfNeeded(pm25: sample.pm25)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Sampling failed."
        }

        isSampling = false
    }

    private func shouldSample(location: CLLocation, forced: Bool) -> Bool {
        guard !forced else { return true }

        let interval = UserDefaults.standard.double(forKey: SettingsKeys.sampleIntervalSeconds)
            .nonZero(defaultValue: Defaults.sampleIntervalSeconds)

        if let lastSampleDate, Date().timeIntervalSince(lastSampleDate) < interval {
            return false
        }

        if let lastSampleLocation,
           location.distance(from: lastSampleLocation) < Defaults.minimumDistanceMeters,
           Date().timeIntervalSince(lastSampleDate ?? .distantPast) < interval * 2 {
            return false
        }

        return true
    }

    private func pruneOldSamples() {
        guard let modelContext else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
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

extension ExposureTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
                beginLocationUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            await process(location: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
            statusMessage = "Location update failed."
        }
    }
}

