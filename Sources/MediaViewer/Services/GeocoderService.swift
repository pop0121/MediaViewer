import CoreData
import CoreLocation
import Foundation

final class GeocoderService: NSObject {
    static let shared = GeocoderService()

    private let geocoder = CLGeocoder()

    /// Minimum delay between reverse-geocoding requests. CLGeocoder is heavily rate-limited;
    /// one request per second is a conservative default that avoids kCLErrorDomain error 2.
    private static let requestDelay: TimeInterval = 1.0

    /// Coordinates that failed in this process lifetime. Persisted as empty string in Core Data,
    /// but this in-memory set prevents retrying the same coordinate repeatedly within one scan.
    private var failedCoordinates = Set<CoordinateKey>()

    /// Look up a cached location name synchronously.
    func cachedName(for coordinate: CLLocationCoordinate2D, in context: NSManagedObjectContext) -> String? {
        let request = NSFetchRequest<LocationNameEntity>(entityName: "LocationNameEntity")
        request.predicate = NSPredicate(format: "latitude == %lf AND longitude == %lf",
                                        coordinate.latitude, coordinate.longitude)
        request.fetchLimit = 1
        return (try? context.fetch(request).first)?.name
    }

    /// Find all indexed items that have coordinates but no cached location name and reverse-geocode them.
    /// If the network is unavailable or rate-limiting kicks in, abort early and mark remaining
    /// coordinates as "Unknown Location" so they are not retried on every refresh.
    func geocodeUncachedCoordinates(
        in context: NSManagedObjectContext,
        onResolved: (@Sendable (GeocodedLocation) async -> Void)? = nil
    ) async {
        let uncachedItems = await context.perform {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            request.predicate = NSPredicate(format: "latitude != 0 AND longitude != 0 AND locationName == nil")
            return (try? context.fetch(request)) ?? []
        }

        guard !uncachedItems.isEmpty else { return }

        // Deduplicate by coordinate so we only geocode each unique location once.
        var itemsByCoordinate: [CoordinateKey: [MediaItemEntity]] = [:]
        for item in uncachedItems {
            let key = CoordinateKey(latitude: item.latitude, longitude: item.longitude)
            itemsByCoordinate[key, default: []].append(item)
        }

        // Drop any coordinates that already failed in this session.
        for failedKey in failedCoordinates {
            itemsByCoordinate.removeValue(forKey: failedKey)
        }

        let coordinateGroups = Array(itemsByCoordinate)
        var consecutiveNetworkFailures = 0
        let maxConsecutiveFailures = 3

        for (index, entry) in coordinateGroups.enumerated() {
            let (key, items) = entry
            let coordinate = key.coordinate
            let result = await reverseGeocode(coordinate: coordinate)

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
                if error == .network {
                    consecutiveNetworkFailures += 1
                    failedCoordinates.insert(key)

                    if consecutiveNetworkFailures >= maxConsecutiveFailures {
                        Log.geocode.error("Reverse geocoding aborted after \(consecutiveNetworkFailures) network failures")
                        await markUnknown(context: context, groups: Array(coordinateGroups.dropFirst(index)))
                        return
                    }
                }

                // No result or other failure: store "Unknown Location" so we don't keep trying.
                await context.perform {
                    for item in items {
                        item.locationName = "Unknown Location"
                    }
                    try? context.save()
                }
            }

            // Throttle requests to avoid kCLErrorDomain error 2.
            if index < coordinateGroups.count - 1 {
                try? await Task.sleep(nanoseconds: UInt64(Self.requestDelay * 1_000_000_000))
            }
        }
    }

    private func markUnknown(context: NSManagedObjectContext, groups: [(key: CoordinateKey, value: [MediaItemEntity])]) async {
        await context.perform {
            for (_, items) in groups {
                for item in items {
                    item.locationName = "Unknown Location"
                }
            }
            try? context.save()
        }
    }

    private func reverseGeocode(coordinate: CLLocationCoordinate2D) async -> Result<String, GeocodeError> {
        // Try Apple's geocoder first (no API key, works offline-ish).
        let appleResult = await reverseGeocodeApple(coordinate: coordinate)

        switch appleResult {
        case .success:
            return appleResult
        case .failure(let error):
            // Fall back to Amap for network or other failures. Amap is usually more reliable in China.
            if let amapName = await AmapGeocoderService.shared.reverseGeocode(coordinate: coordinate),
               !amapName.isEmpty {
                return .success(amapName)
            }
            return .failure(error)
        }
    }

    private func reverseGeocodeApple(coordinate: CLLocationCoordinate2D) async -> Result<String, GeocodeError> {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else {
                return .failure(.noResult)
            }

            let components = [
                placemark.locality,
                placemark.administrativeArea,
                placemark.country
            ].compactMap { $0 }

            if components.isEmpty {
                return .success(placemark.name ?? "Unknown Location")
            }
            return .success(components.joined(separator: ", "))
        } catch {
            if let clError = error as? CLError {
                switch clError.code {
                case .geocodeFoundNoResult:
                    return .failure(.noResult)
                case .network:
                    return .failure(.network)
                default:
                    break
                }
            }
            Log.geocode.error("Reverse geocoding failed for \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failure(.other)
        }
    }
}

private enum GeocodeError: Error {
    case noResult
    case network
    case other
}

/// A resolved place for one coordinate, delivered to the UI as soon as it is known.
struct GeocodedLocation: Sendable {
    let latitude: Double
    let longitude: Double
    let name: String
}

private struct CoordinateKey: Hashable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
