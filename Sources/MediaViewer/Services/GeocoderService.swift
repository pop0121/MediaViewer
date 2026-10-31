import CoreData
import CoreLocation
import Foundation

final class GeocoderService: @unchecked Sendable {
    static let shared = GeocoderService()

    private let amap: any ReverseGeocodingBackend
    private let nominatim: any ReverseGeocodingBackend

    /// Minimum delay between reverse-geocoding requests. Nominatim also
    /// enforces its own 1 req/s limit, so this is an upper bound for Amap.
    private static let requestDelay: TimeInterval = 1.0

    init(
        amap: any ReverseGeocodingBackend = AmapGeocoderService.shared,
        nominatim: any ReverseGeocodingBackend = NominatimGeocoderService.shared
    ) {
        self.amap = amap
        self.nominatim = nominatim
    }

    /// Look up a cached location name synchronously.
    func cachedName(for coordinate: CLLocationCoordinate2D, in context: NSManagedObjectContext) -> String? {
        let request = NSFetchRequest<LocationNameEntity>(entityName: "LocationNameEntity")
        request.predicate = NSPredicate(format: "latitude == %lf AND longitude == %lf",
                                        coordinate.latitude, coordinate.longitude)
        request.fetchLimit = 1
        return (try? context.fetch(request).first)?.name
    }

    /// Find indexed items that have coordinates but no usable location name and
    /// reverse-geocode them. Failures are left unresolved (nil or the legacy
    /// "Unknown Location" placeholder) so a later scan retries them.
    func geocodeUncachedCoordinates(
        in context: NSManagedObjectContext,
        onResolved: (@Sendable (GeocodedLocation) async -> Void)? = nil
    ) async {
        let uncachedItems = await context.perform {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            request.predicate = NSPredicate(
                format: "latitude != 0 AND longitude != 0 AND (locationName == nil OR locationName == %@)",
                "Unknown Location"
            )
            return (try? context.fetch(request)) ?? []
        }

        guard !uncachedItems.isEmpty else { return }

        // Deduplicate by coordinate so we only geocode each unique location once.
        var itemsByCoordinate: [CoordinateKey: [MediaItemEntity]] = [:]
        for item in uncachedItems {
            let key = CoordinateKey(latitude: item.latitude, longitude: item.longitude)
            itemsByCoordinate[key, default: []].append(item)
        }

        let coordinateGroups = Array(itemsByCoordinate)
        var consecutiveNetworkFailures = 0
        let maxConsecutiveFailures = 3

        for (index, entry) in coordinateGroups.enumerated() {
            if Task.isCancelled { return }
            let (key, items) = entry
            let coordinate = key.coordinate
            let result = await resolveName(coordinate: coordinate)

            switch result {
            case .success(let name):
                consecutiveNetworkFailures = 0
                await context.perform {
                    for item in items {
                        item.locationName = name
                    }

                    let cached = self.cachedName(for: coordinate, in: context)
                    if cached == nil {
                        let entity = LocationNameEntity(context: context)
                        entity.latitude = coordinate.latitude
                        entity.longitude = coordinate.longitude
                        entity.name = name
                    }

                    try? context.save()
                }

                if let onResolved {
                    await onResolved(GeocodedLocation(latitude: coordinate.latitude,
                                                      longitude: coordinate.longitude,
                                                      name: name))
                }

            case .failure(let error):
                Log.geocode.error("Geocoding failed for \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public): \(String(describing: error), privacy: .public); will retry")
                if error == .network {
                    consecutiveNetworkFailures += 1
                    if consecutiveNetworkFailures >= maxConsecutiveFailures {
                        Log.geocode.error("Reverse geocoding aborted after \(consecutiveNetworkFailures) network failures; leaving names unresolved")
                        return
                    }
                }
            }

            if index < coordinateGroups.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(Self.requestDelay * 1_000_000_000))
            }
        }
    }

    /// Resolve one coordinate. China prefers Amap (better local names); other
    /// regions prefer Nominatim (no key required). A failure falls back to the
    /// other backend.
    func resolveName(coordinate: CLLocationCoordinate2D) async -> Result<String, GeocodeError> {
        let preferred: any ReverseGeocodingBackend
        let fallback: any ReverseGeocodingBackend
        if CoordinateConverter.isInChina(coordinate) {
            preferred = amap
            fallback = nominatim
        } else {
            preferred = nominatim
            fallback = amap
        }

        var firstError: GeocodeError = .other
        switch await preferred.reverseGeocode(coordinate: coordinate) {
        case .success(let name):
            return .success(name)
        case .failure(let error):
            firstError = error
            Log.geocode.notice("\(preferred.backendName, privacy: .public) failed; trying \(fallback.backendName, privacy: .public)")
        }

        switch await fallback.reverseGeocode(coordinate: coordinate) {
        case .success(let name):
            return .success(name)
        case .failure:
            return .failure(firstError)
        }
    }
}

/// A resolved place for one coordinate, delivered to the UI as soon as it is known.
struct GeocodedLocation: Sendable {
    let latitude: Double
    let longitude: Double
    let name: String
}
