import Foundation

enum IDWInterpolatorError: LocalizedError {
    case noReadings

    var errorDescription: String? {
        "No valid PM2.5 readings are available for interpolation."
    }
}

enum IDWInterpolator {
    static func interpolate(
        at coordinate: Coordinate,
        readings: [StationReading],
        nearestCount: Int = 5,
        power: Double = 2
    ) throws -> InterpolationResult {
        let readingsWithDistance = readings
            .map { reading -> (StationReading, Double) in
                let distance = haversineMeters(
                    from: coordinate,
                    to: Coordinate(latitude: reading.latitude, longitude: reading.longitude)
                )
                return (reading, distance)
            }
            .sorted { $0.1 < $1.1 }

        guard !readingsWithDistance.isEmpty else {
            throw IDWInterpolatorError.noReadings
        }

        if let nearest = readingsWithDistance.first, nearest.1 < 1 {
            return InterpolationResult(
                coordinate: coordinate,
                pm25: nearest.0.pm25,
                usedReadings: [nearest.0]
            )
        }

        let selected = Array(readingsWithDistance.prefix(max(1, min(nearestCount, readingsWithDistance.count))))

        if selected.count == 1 {
            return InterpolationResult(
                coordinate: coordinate,
                pm25: selected[0].0.pm25,
                usedReadings: [selected[0].0]
            )
        }

        let weighted = selected.reduce(into: (numerator: 0.0, denominator: 0.0)) { partial, item in
            let safeDistance = max(item.1, 1)
            let weight = 1 / pow(safeDistance, power)
            partial.numerator += item.0.pm25 * weight
            partial.denominator += weight
        }

        return InterpolationResult(
            coordinate: coordinate,
            pm25: weighted.numerator / weighted.denominator,
            usedReadings: selected.map(\.0)
        )
    }

    static func haversineMeters(from start: Coordinate, to end: Coordinate) -> Double {
        let radius = 6_371_000.0
        let lat1 = start.latitude.radians
        let lat2 = end.latitude.radians
        let deltaLat = (end.latitude - start.latitude).radians
        let deltaLon = (end.longitude - start.longitude).radians

        let a = pow(sin(deltaLat / 2), 2)
            + cos(lat1) * cos(lat2) * pow(sin(deltaLon / 2), 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return radius * c
    }
}

private extension Double {
    var radians: Double {
        self * .pi / 180
    }
}

#if DEBUG
enum IDWInterpolatorSelfTest {
    static func run() -> Bool {
        let origin = Coordinate(latitude: 32.8801, longitude: -117.2340)
        let north = Coordinate(latitude: 32.8901, longitude: -117.2340)
        let south = Coordinate(latitude: 32.8701, longitude: -117.2340)
        let readings = [
            StationReading(
                id: 1,
                locationID: 1,
                name: "North",
                latitude: north.latitude,
                longitude: north.longitude,
                pm25: 10,
                measuredAt: nil,
                distanceMeters: nil
            ),
            StationReading(
                id: 2,
                locationID: 2,
                name: "South",
                latitude: south.latitude,
                longitude: south.longitude,
                pm25: 30,
                measuredAt: nil,
                distanceMeters: nil
            )
        ]

        guard let result = try? IDWInterpolator.interpolate(at: origin, readings: readings, nearestCount: 2) else {
            return false
        }

        return abs(result.pm25 - 20) < 0.5
    }
}
#endif

