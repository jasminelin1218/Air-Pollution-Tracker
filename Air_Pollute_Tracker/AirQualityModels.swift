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
    static let trackingDays = "trackingDays"
}

enum TrackingDuration: Int, CaseIterable, Identifiable {
    case oneHour = 0
    case oneDay = 1
    case sevenDays = 7

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .oneHour: return "1 Hour"
        case .oneDay: return "1 Day"
        case .sevenDays: return "7 Days"
        }
    }

    var reportTitle: String {
        switch self {
        case .oneHour: return "Hourly Exposure Report"
        case .oneDay: return "Daily Exposure Report"
        case .sevenDays: return "Weekly Exposure Report"
        }
    }

    var reportWindowDescription: String {
        switch self {
        case .oneHour: return "one-hour"
        case .oneDay: return "24-hour"
        case .sevenDays: return "seven-day"
        }
    }

    var windowInterval: TimeInterval {
        switch self {
        case .oneHour: return 60.0 * 60.0
        case .oneDay: return 24.0 * 60.0 * 60.0
        case .sevenDays: return 7.0 * 24.0 * 60.0 * 60.0
        }
    }
}

enum Defaults {
    static let alertThreshold = 35.5
    static let sampleIntervalSeconds = 15.0 * 60.0
    static let searchRadiusMeters = 25_000
    static let minimumDistanceMeters = 150.0
}

