import Foundation

enum OpenAQClientError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int)
    case noPM25SensorsNearby

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAQ API key in Settings before sampling."
        case .invalidResponse:
            return "OpenAQ returned a response the app could not read."
        case .requestFailed(let statusCode):
            return "OpenAQ request failed with status \(statusCode)."
        case .noPM25SensorsNearby:
            return "No nearby PM2.5 stations with latest readings were found."
        }
    }
}

struct OpenAQClient {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.openaq.org/v3")!

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    func fetchPM25Readings(
        near coordinate: Coordinate,
        radiusMeters: Int = 25_000,
        limit: Int = 50
    ) async throws -> [StationReading] {
        guard !apiKey.isEmpty else {
            throw OpenAQClientError.missingAPIKey
        }

        let locations = try await fetchLocations(
            near: coordinate,
            radiusMeters: radiusMeters,
            limit: limit
        )
        let pm25Locations = locations.filter(\.hasPM25Sensor)
        var readings: [StationReading] = []

        for location in pm25Locations.prefix(limit) {
            if let reading = try await fetchLatestPM25(for: location) {
                readings.append(reading)
            }
        }

        guard !readings.isEmpty else {
            throw OpenAQClientError.noPM25SensorsNearby
        }

        return readings.sorted {
            ($0.distanceMeters ?? .greatestFiniteMagnitude) < ($1.distanceMeters ?? .greatestFiniteMagnitude)
        }
    }

    private func fetchLocations(
        near coordinate: Coordinate,
        radiusMeters: Int,
        limit: Int
    ) async throws -> [OpenAQLocation] {
        var components = URLComponents(url: baseURL.appending(path: "locations"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "coordinates", value: "\(coordinate.latitude),\(coordinate.longitude)"),
            URLQueryItem(name: "radius", value: "\(radiusMeters)"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        let response: OpenAQResponse<OpenAQLocation> = try await request(components.url!)
        return response.results
    }

    private func fetchLatestPM25(for location: OpenAQLocation) async throws -> StationReading? {
        let url = baseURL.appending(path: "locations/\(location.id)/latest")
        let response: OpenAQResponse<OpenAQLatestMeasurement> = try await request(url)
        guard let measurement = response.results.first(where: { $0.isPM25 }) else {
            return nil
        }

        let latitude = measurement.coordinates?.latitude ?? location.coordinates.latitude
        let longitude = measurement.coordinates?.longitude ?? location.coordinates.longitude

        guard let latitude, let longitude else {
            return nil
        }

        return StationReading(
            id: measurement.sensorID ?? location.id,
            locationID: location.id,
            name: location.name ?? "OpenAQ location \(location.id)",
            latitude: latitude,
            longitude: longitude,
            pm25: measurement.value,
            measuredAt: measurement.datetime?.utcDate,
            distanceMeters: location.distance
        )
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAQClientError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw OpenAQClientError.requestFailed(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder.openAQ.decode(T.self, from: data)
        } catch {
            throw OpenAQClientError.invalidResponse
        }
    }
}

private extension JSONDecoder {
    static var openAQ: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private struct OpenAQResponse<Result: Decodable>: Decodable {
    let results: [Result]
}

private struct OpenAQLocation: Decodable {
    let id: Int
    let name: String?
    let coordinates: OpenAQCoordinates
    let sensors: [OpenAQSensor]
    let distance: Double?

    var hasPM25Sensor: Bool {
        sensors.contains { $0.parameter.isPM25 }
    }
}

private struct OpenAQSensor: Decodable {
    let id: Int
    let name: String?
    let parameter: OpenAQParameter
}

private struct OpenAQParameter: Decodable {
    let id: Int?
    let name: String?
    let displayName: String?
    let units: String?

    var isPM25: Bool {
        let normalized = [name, displayName]
            .compactMap { $0?.lowercased().replacingOccurrences(of: " ", with: "") }
        return normalized.contains { value in
            value == "pm25" || value == "pm2.5" || value.contains("pm2.5")
        } || id == 2
    }
}

private struct OpenAQCoordinates: Decodable {
    let latitude: Double?
    let longitude: Double?
}

private struct OpenAQLatestMeasurement: Decodable {
    let value: Double
    let datetime: OpenAQDateTime?
    let coordinates: OpenAQCoordinates?
    let parameter: OpenAQParameter?
    private let sensorsID: Int?
    private let sensorsId: Int?

    var isPM25: Bool {
        parameter?.isPM25 ?? true
    }

    var sensorID: Int? {
        sensorsID ?? sensorsId
    }

    enum CodingKeys: String, CodingKey {
        case value
        case datetime
        case coordinates
        case parameter
        case sensorsID
        case sensorsId
    }
}

private struct OpenAQDateTime: Decodable {
    let utc: String?
    let local: String?

    var utcDate: Date? {
        guard let utc else { return nil }
        return ISO8601DateFormatter.openAQWithFractionalSeconds.date(from: utc)
            ?? ISO8601DateFormatter.openAQ.date(from: utc)
    }
}

private extension ISO8601DateFormatter {
    static let openAQWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let openAQ: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

