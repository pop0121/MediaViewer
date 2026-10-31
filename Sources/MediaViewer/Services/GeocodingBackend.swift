import CoreLocation

enum GeocodeError: Error, Equatable {
    case noResult
    case network
    case other
}

/// A reverse-geocoding provider. Implementations must be safe to call from
/// any task; they return a human-readable place name or an error.
protocol ReverseGeocodingBackend: Sendable {
    var backendName: String { get }
    func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> Result<String, GeocodeError>
}

struct CoordinateKey: Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
