import CoreLocation
import Foundation

/// Amap (Gaode) reverse-geocoding backend, preferred inside China.
final class AmapGeocoderService: ReverseGeocodingBackend, @unchecked Sendable {
    static let shared = AmapGeocoderService(apiKey: configuredAPIKey)

    var backendName: String { "amap" }

    /// The key is never committed: configure it via `MEDIAVIEWER_AMAP_KEY` or
    /// the `AmapAPIKey` entry in the app's Info.plist.
    static var configuredAPIKey: String? {
        let env = ProcessInfo.processInfo.environment["MEDIAVIEWER_AMAP_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "AmapAPIKey") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private let apiKey: String?
    private let session: URLSession

    init(apiKey: String?) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        if apiKey == nil {
            Log.geocode.notice("Amap API key not configured; falling back to Nominatim")
        }
    }

    /// Reverse-geocode a WGS-84 coordinate using Amap.
    func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> Result<String, GeocodeError> {
        guard let apiKey, !apiKey.isEmpty else { return .failure(.other) }

        let gcj = CoordinateConverter.wgs84ToGcj02(coordinate)
        let location = String(format: "%.6f,%.6f", gcj.longitude, gcj.latitude)
        let endpoint = "https://restapi.amap.com/v3/geocode/regeo"
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "location", value: location),
            URLQueryItem(name: "extensions", value: "base"),
            URLQueryItem(name: "output", value: "JSON")
        ]

        guard let url = components.url else { return .failure(.other) }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return .failure(.other)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String,
                  status == "1",
                  let regeocode = json["regeocode"] as? [String: Any],
                  let formattedAddress = regeocode["formatted_address"] as? String,
                  !formattedAddress.isEmpty else {
                // Quota exhaustion and no-result both land here; the caller
                // falls back to the other backend.
                return .failure(.other)
            }

            let shortName = shortPlaceName(from: regeocode["addressComponent"] as? [String: Any])
            return .success(shortName ?? formattedAddress)
        } catch let error as URLError {
            Log.geocode.error("Amap network failure for \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(.network)
        } catch {
            Log.geocode.error("Amap reverse geocoding failed for \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(.other)
        }
    }

    private func shortPlaceName(from component: [String: Any]?) -> String? {
        guard let component else { return nil }

        let province = stringOrFirstElement(from: component["province"])
        let city = stringOrFirstElement(from: component["city"])
        let district = stringOrFirstElement(from: component["district"])
        let township = stringOrFirstElement(from: component["township"])
        let street = stringOrFirstElement(from: (component["streetNumber"] as? [String: Any])?["street"])

        let parts = [province, city, district, township, street]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    /// Amap sometimes returns a string and sometimes an array (often empty) for the same field.
    private func stringOrFirstElement(from value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let array = value as? [Any], let first = array.first as? String, !first.isEmpty {
            return first
        }
        return nil
    }
}

// MARK: - Coordinate Conversion (WGS-84 → GCJ-02)

enum CoordinateConverter {
    private static let a: Double = 6378245.0
    private static let ee: Double = 0.00669342162296594323

    /// Convert a WGS-84 coordinate (GPS/Apple/EXIF) to GCJ-02 for Chinese map services.
    /// Rough mainland-China bounding box used to pick a preferred backend.
    static func isInChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        isInChina(lng: coordinate.longitude, lat: coordinate.latitude)
    }

    static func wgs84ToGcj02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let lng = coordinate.longitude
        let lat = coordinate.latitude

        if !isInChina(lng: lng, lat: lat) {
            return coordinate
        }

        var dLat = transformLat(lng - 105.0, lat - 35.0)
        var dLng = transformLng(lng - 105.0, lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: lat + dLat, longitude: lng + dLng)
    }

    private static func isInChina(lng: Double, lat: Double) -> Bool {
        return lng >= 72.004 && lng <= 137.8347 && lat >= 0.8293 && lat <= 55.8271
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
