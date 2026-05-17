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
}

