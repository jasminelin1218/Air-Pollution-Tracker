import Foundation

struct WeeklyExposureSummary {
    let trackedSeconds: Double
    let timeWeightedAveragePM25: Double
    let peakPM25: Double
    let highExposureSeconds: Double
    let sampleCount: Int
    let dailyBreakdown: [DailyExposureSummary]

    static let empty = WeeklyExposureSummary(
        trackedSeconds: 0,
        timeWeightedAveragePM25: 0,
        peakPM25: 0,
        highExposureSeconds: 0,
        sampleCount: 0,
        dailyBreakdown: []
    )
}

struct DailyExposureSummary: Identifiable {
    let id = UUID()
    let date: Date
    let averagePM25: Double
    let peakPM25: Double
    let sampleCount: Int
}

/// Snapshot shown when the user stops tracking (session-scoped metrics).
struct StopTrackingReport: Identifiable {
    let id = UUID()
    let sessionStart: Date
    let sessionEnd: Date
    /// Sampling cadence from Settings (used for this session’s TWA gap cap).
    let sampleIntervalSeconds: Double
    /// Alert threshold from Settings (high-exposure time uses this bar).
    let alertThreshold: Double
    let summary: WeeklyExposureSummary

    var sessionDurationDescription: String {
        sessionEnd.formattedTimeSince(sessionStart)
    }

    /// Same rule as `stopTracking()` / `WeeklyExposureReport` for this session.
    var twaMaxGapSeconds: Double {
        let dur = max(sessionEnd.timeIntervalSince(sessionStart), 1)
        return min(sampleIntervalSeconds * 2, dur / 4)
    }

    /// Human-readable cap for UI footnotes (minutes if under 1 hr).
    var twaMaxGapDescription: String {
        let s = twaMaxGapSeconds
        if s >= 3600 {
            return s.formattedDurationHours
        }
        return (s / 60).formatted(.number.precision(.fractionLength(0))) + " min"
    }
}

enum WeeklyExposureReport {
    /// - Parameter referenceEndDate: When set (e.g. session end), forward-exposure time after the last sample is capped to this instant instead of "now".
    static func summarize(
        samples: [ExposureSample],
        threshold: Double,
        maxGapSeconds: Double = Defaults.sampleIntervalSeconds * 2,
        referenceEndDate: Date? = nil
    ) -> WeeklyExposureSummary {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else {
            return .empty
        }

        var weightedSum = 0.0
        var trackedSeconds = 0.0
        var highExposureSeconds = 0.0
        let now = referenceEndDate ?? Date()

        for index in ordered.indices {
            let sample = ordered[index]
            let nextDate = index < ordered.index(before: ordered.endIndex)
                ? ordered[ordered.index(after: index)].timestamp
                : now
            let seconds = max(0, min(nextDate.timeIntervalSince(sample.timestamp), maxGapSeconds))
            weightedSum += sample.pm25 * seconds
            trackedSeconds += seconds

            if sample.pm25 >= threshold {
                highExposureSeconds += seconds
            }
        }

        let groupedByDay = Dictionary(grouping: ordered) { sample in
            Calendar.current.startOfDay(for: sample.timestamp)
        }

        let dailyBreakdown = groupedByDay
            .map { date, daySamples in
                DailyExposureSummary(
                    date: date,
                    averagePM25: daySamples.map(\.pm25).reduce(0, +) / Double(daySamples.count),
                    peakPM25: daySamples.map(\.pm25).max() ?? 0,
                    sampleCount: daySamples.count
                )
            }
            .sorted { $0.date < $1.date }

        return WeeklyExposureSummary(
            trackedSeconds: trackedSeconds,
            timeWeightedAveragePM25: trackedSeconds > 0 ? weightedSum / trackedSeconds : ordered.map(\.pm25).reduce(0, +) / Double(ordered.count),
            peakPM25: ordered.map(\.pm25).max() ?? 0,
            highExposureSeconds: highExposureSeconds,
            sampleCount: ordered.count,
            dailyBreakdown: dailyBreakdown
        )
    }
}

