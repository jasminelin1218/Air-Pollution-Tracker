import CoreLocation
import Foundation
import SwiftUI
import UIKit

// MARK: - CSV (Excel-compatible)

/// Builds a UTF-8 CSV of all retained exposure samples. Read-only: safe to call while tracking runs.
enum TrackingHistoryCSVExport {
    private static let isoTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    /// US Pacific wall clock (PST / PDT per DST rules).
    private static let pacificFormatter: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(identifier: "America/Los_Angeles")
        d.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return d
    }()

    private static let localSampleFormatter: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return d
    }()

    private static let fileNameDate: DateFormatter = {
        let d = DateFormatter()
        d.locale = Locale(identifier: "en_US_POSIX")
        d.timeZone = TimeZone(secondsFromGMT: 0)
        d.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return d
    }()

    /// RFC 4180-style escaping for comma-separated output.
    static func csvEscaped(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Human-readable `(City, Country)` using reverse-geocode fields when present.
    private static func bracketPlace(from placemark: CLPlacemark?) -> String {
        guard let placemark else {
            return "(unknown location)"
        }
        let city =
            placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? "Unknown place"
        let countryPart = countryLabel(for: placemark)
        if countryPart.isEmpty {
            return "(\(city))"
        }
        return "(\(city), \(countryPart))"
    }

    private static func countryLabel(for placemark: CLPlacemark) -> String {
        if let code = placemark.isoCountryCode?.uppercased() {
            switch code {
            case "US":
                return "USA"
            case "GB":
                return "UK"
            default:
                return Locale(identifier: "en_US_POSIX").localizedString(forRegionCode: code)
                    ?? placemark.country
                    ?? code
            }
        }
        return placemark.country ?? ""
    }

    /// Sample instant in the placemark’s timezone when available; suffix is `(City, Country)`.
    private static func localTimeAndPlaceColumn(timestamp: Date, placemark: CLPlacemark?) -> String {
        localSampleFormatter.timeZone = placemark?.timeZone ?? TimeZone(secondsFromGMT: 0)
        let timePart = localSampleFormatter.string(from: timestamp)
        return "\(timePart) \(bracketPlace(from: placemark))"
    }

    /// Pass samples **newest first** (latest row immediately below the header).
    /// Reverse-geocodes sequentially (Apple allows one `CLGeocoder` request at a time); caches rounded coordinates.
    @MainActor
    static func csvString(samplesOrderedNewestFirst samples: [ExposureSample]) async -> String {
        let header = [
            "Sample_ID",
            "Timestamp_UTC",
            "Timestamp_Pacific",
            "Local_Time_And_Place",
            "Latitude",
            "Longitude",
            "Horizontal_Accuracy_m",
            "PM25_ug_m3",
            "Station_Count",
            "Source_Stations",
            "Contributor_Snapshots_JSON",
        ].joined(separator: ",")

        var lines: [String] = [header]
        lines.reserveCapacity(samples.count + 1)

        let cache = ExportReverseGeocodeCache()
        for s in samples {
            let placemark = await cache.placemark(latitude: s.latitude, longitude: s.longitude)
            let row: [String] = [
                csvEscaped(s.id.uuidString),
                csvEscaped(isoTimestamp.string(from: s.timestamp)),
                csvEscaped(pacificFormatter.string(from: s.timestamp)),
                csvEscaped(localTimeAndPlaceColumn(timestamp: s.timestamp, placemark: placemark)),
                String(s.latitude),
                String(s.longitude),
                String(s.horizontalAccuracy),
                String(s.pm25),
                String(s.stationCount),
                csvEscaped(s.sourceSummary),
                csvEscaped(s.contributorSnapshotsJSON),
            ]
            lines.append(row.joined(separator: ","))
        }

        return lines.joined(separator: "\r\n")
    }

    /// UTF-8 with BOM so Excel recognizes Unicode station names; written to a unique temp file.
    /// Pass samples **newest first**. Performs reverse geocoding (may take a while for many distinct locations).
    @MainActor
    static func writeTempCSVFile(samplesOrderedNewestFirst samples: [ExposureSample]) async throws -> URL {
        let csv = await csvString(samplesOrderedNewestFirst: samples)
        let bom = "\u{FEFF}"
        guard let data = (bom + csv).data(using: .utf8) else {
            throw TrackingHistoryExportError.encodingFailed
        }
        let base = fileNameDate.string(from: Date())
        let fileName = "AirPollute_Tracking_\(base).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Reverse geocode (export only)

/// One geocoder instance; Apple recommends only one reverse request at a time.
@MainActor
private final class ExportReverseGeocodeCache {
    private let geocoder = CLGeocoder()
    /// Successful lookups only (same rounded coordinate → reuse placemark).
    private var cache: [String: CLPlacemark] = [:]

    func placemark(latitude: Double, longitude: Double) async -> CLPlacemark? {
        let key = "\(latitude.rounded(toPlaces: 4)),\(longitude.rounded(toPlaces: 4))"
        if let cached = cache[key] {
            return cached
        }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = await reverseGeocode(location) else {
            return nil
        }
        cache[key] = placemark
        return placemark
    }

    private func reverseGeocode(_ location: CLLocation) async -> CLPlacemark? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLPlacemark?, Never>) in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                continuation.resume(returning: placemarks?.first)
            }
        }
    }
}

enum TrackingHistoryExportError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the export file."
        }
    }
}

// MARK: - Share sheet

/// Presents `UIActivityViewController` for sharing a generated file (e.g. CSV).
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
