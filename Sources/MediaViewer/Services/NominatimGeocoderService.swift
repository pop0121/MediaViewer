import CoreLocation
import Foundation

/// Serializes Nominatim requests and enforces its public 1 request/second
/// usage policy. Actor isolation makes concurrent callers queue up.
actor RequestThrottle {
    private let interval: TimeInterval
    private var lastRequest: TimeInterval = 0

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func acquire() async {
        while true {
            let now = Date().timeIntervalSince1970
            let remaining = interval - (now - lastRequest)
            if remaining <= 0 {
                lastRequest = now
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }
}

/// Nominatim (OpenStreetMap) reverse geocoding. Requires no API key, but its
/// usage policy requires an identifying User-Agent and at most 1 request/s.
final class NominatimGeocoderService: ReverseGeocodingBackend, @unchecked Sendable {
    static let shared = NominatimGeocoderService()

    var backendName: String { "nominatim" }

    private let session: URLSession
    private let throttle = RequestThrottle(interval: 1.0)
    private let cache = NSCache<NSString, NSString>()
    private let contact: String

    init(contact: String? = nil, session: URLSession? = nil) {
        self.contact = contact ?? Self.configuredContact
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)
        }
        cache.countLimit = 2_000
    }

    /// Contact string for the User-Agent. Configure via
    /// `MEDIAVIEWER_NOMINATIM_CONTACT` or the `NominatimContact` Info.plist key.
    static var configuredContact: String {
        let env = ProcessInfo.processInfo.environment["MEDIAVIEWER_NOMINATIM_CONTACT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let env, !env.isEmpty { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "NominatimContact") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return "\(NSUserName())@localhost"
    }

    var userAgent: String {
        "MediaViewer/1.0 (contact: \(contact))"
    }

    func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> Result<String, GeocodeError> {
        let key = "\(coordinate.latitude),\(coordinate.longitude)" as NSString
        if let cached = cache.object(forKey: key) {
            return .success(cached as String)
        }

        await throttle.acquire()
        guard !Task.isCancelled else { return .failure(.other) }

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/reverse")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "lat", value: String(format: "%.7f", coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.7f", coordinate.longitude)),
            URLQueryItem(name: "zoom", value: "14"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "accept-language", value: "zh-CN,zh,en")
        ]
        guard let url = components.url else { return .failure(.other) }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.other) }
            guard http.statusCode == 200 else {
                Log.geocode.error("Nominatim HTTP \(http.statusCode, privacy: .public)")
                return .failure(.other)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let displayName = json["display_name"] as? String,
                  !displayName.isEmpty else {
                return .failure(.noResult)
            }

            let name = shortPlaceName(address: json["address"] as? [String: Any]) ?? displayName
            cache.setObject(name as NSString, forKey: key)
            return .success(name)
        } catch let error as URLError where error.code != .cancelled {
            Log.geocode.error("Nominatim network failure: \(error.localizedDescription, privacy: .public)")
            return .failure(.network)
        } catch {
            return .failure(.other)
        }
    }

    private func shortPlaceName(address: [String: Any]?) -> String? {
        guard let address else { return nil }
        let keys = ["city", "town", "village", "municipality", "county", "state", "country"]
        var parts: [String] = []
        for key in keys {
            guard let value = address[key] as? String, !value.isEmpty, !parts.contains(value) else { continue }
            parts.append(value)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
