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

    static func csvString(from samples: [ExposureSample]) -> String {
        let header = [
            "Sample_ID",
            "Timestamp_UTC",
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

        for s in samples {
            let row: [String] = [
                csvEscaped(s.id.uuidString),
                csvEscaped(isoTimestamp.string(from: s.timestamp)),
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
    static func writeTempCSVFile(allSamplesSortedAscending: [ExposureSample]) throws -> URL {
        let csv = csvString(from: allSamplesSortedAscending)
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
