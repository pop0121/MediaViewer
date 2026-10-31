import CoreLocation
import MapKit

/// A latitude/longitude rectangle used for map-area filtering of the grid.
struct GeoBounds: Equatable, Sendable {
    let minLatitude: Double
    let maxLatitude: Double
    let minLongitude: Double
    let maxLongitude: Double

    init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = max(-90, min(90, minLatitude))
        self.maxLatitude = max(-90, min(90, maxLatitude))
        self.minLongitude = max(-180, min(180, minLongitude))
        self.maxLongitude = max(-180, min(180, maxLongitude))
    }

    init?(region: MKCoordinateRegion) {
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        guard halfLat.isFinite, halfLon.isFinite, halfLat > 0, halfLon > 0 else { return nil }
        self.init(
            minLatitude: region.center.latitude - halfLat,
            maxLatitude: region.center.latitude + halfLat,
            minLongitude: region.center.longitude - halfLon,
            maxLongitude: region.center.longitude + halfLon
        )
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= minLatitude && coordinate.latitude <= maxLatitude
            && coordinate.longitude >= minLongitude && coordinate.longitude <= maxLongitude
    }
}
