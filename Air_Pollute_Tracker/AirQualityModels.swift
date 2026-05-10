import Foundation
import SwiftData

struct StationReading: Identifiable, Hashable {
    let id: Int
    let locationID: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let pm25: Double
    let measuredAt: Date?
    let distanceMeters: Double?
}

struct InterpolationResult {
    let coordinate: Coordinate
    let pm25: Double
    let usedReadings: [StationReading]
}

struct Coordinate: Hashable {
    let latitude: Double
    let longitude: Double
}

@Model
final class ExposureSample {
    var id: UUID
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var pm25: Double
    var stationCount: Int
    var sourceSummary: String

    init(
        id: UUID = UUID(),
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        pm25: Double,
        stationCount: Int,
        sourceSummary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.pm25 = pm25
        self.stationCount = stationCount
        self.sourceSummary = sourceSummary
    }
}

enum SettingsKeys {
    static let openAQAPIKey = "openAQAPIKey"
    static let alertThreshold = "alertThreshold"
    static let sampleIntervalSeconds = "sampleIntervalSeconds"
}

enum Defaults {
    static let alertThreshold = 35.5
    static let sampleIntervalSeconds = 15.0 * 60.0
    static let searchRadiusMeters = 25_000
    static let minimumDistanceMeters = 150.0
}

