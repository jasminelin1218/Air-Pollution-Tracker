import Foundation

extension Double {
    func nonZero(defaultValue: Double) -> Double {
        self > 0 ? self : defaultValue
    }

    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }

    var formattedPM25: String {
        formatted(.number.precision(.fractionLength(1))) + " ug/m3"
    }

    var formattedDurationHours: String {
        let hours = self / 3600
        return hours.formatted(.number.precision(.fractionLength(1))) + " hr"
    }

    /// Label for OpenAQ sampling cadence (15 / 30 / 60 min from Settings).
    var formattedSamplingIntervalLabel: String {
        let sec = nonZero(defaultValue: Defaults.sampleIntervalSeconds)
        let minutes = sec / 60.0
        if abs(minutes - 60) < 0.01 {
            return "60 minutes (1 hour)"
        }
        let m = Int(minutes.rounded())
        return "\(m) minutes"
    }

    /// Formats haversine distance to the station (meters → m or km).
    var formattedStationDistance: String {
        if self < 1_000 {
            return formatted(.number.precision(.fractionLength(0))) + " m"
        }
        let km = self / 1_000
        return km.formatted(.number.precision(.fractionLength(1))) + " km"
    }
}

extension Int {
    func nonZero(defaultValue: Int) -> Int {
        self > 0 ? self : defaultValue
    }
}

extension Date {
    var shortTimeString: String {
        formatted(date: .omitted, time: .shortened)
    }

    var shortDateTimeString: String {
        formatted(date: .abbreviated, time: .shortened)
    }

    /// Wall-clock session length for stop-tracking reports.
    func formattedTimeSince(_ start: Date) -> String {
        let sec = max(0, timeIntervalSince(start))
        if sec >= 3600 {
            let h = sec / 3600
            return h.formatted(.number.precision(.fractionLength(1))) + " hr"
        }
        let m = sec / 60
        return m.formatted(.number.precision(.fractionLength(0))) + " min"
    }
}

