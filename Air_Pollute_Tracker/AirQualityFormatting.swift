import Foundation

extension Double {
    func nonZero(defaultValue: Double) -> Double {
        self > 0 ? self : defaultValue
    }

    var formattedPM25: String {
        formatted(.number.precision(.fractionLength(1))) + " ug/m3"
    }

    var formattedDurationHours: String {
        let hours = self / 3600
        return hours.formatted(.number.precision(.fractionLength(1))) + " hr"
    }
}

extension Date {
    var shortTimeString: String {
        formatted(date: .omitted, time: .shortened)
    }

    var shortDateTimeString: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}

