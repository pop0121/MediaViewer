import CoreLocation
import Foundation
import MapKit

/// One map annotation: either a single photo or a grid bucket of photos.
struct PhotoCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let items: [MediaItem]

    var count: Int { items.count }

    var title: String {
        if let name = mostCommonLocationName {
            return name
        }
        if items.count == 1 {
            return items[0].fileName
        }
        return "\(items.count) photos"
    }

    private var mostCommonLocationName: String? {
        var counts: [String: Int] = [:]
        for item in items {
            guard let name = item.locationName, !name.isEmpty, name != "Unknown Location" else { continue }
            counts[name, default: 0] += 1
        }
        return counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
    }
}

/// Local, dependency-free clustering. Points are bucketed into an adaptive
/// latitude/longitude grid chosen to produce roughly `target` clusters for the
/// current visible region. All work is O(points × grid candidates) and does not
/// touch the network.
enum PlacesClusterer {
    static let defaultTarget = 20...60

    static func clusters(
        items: [MediaItem],
        region: MKCoordinateRegion,
        margin: Double = 0.15,
        target: ClosedRange<Int> = defaultTarget
    ) -> [PhotoCluster] {
        let visible = items.filter { item in
            guard let coordinate = item.coordinate, isValid(coordinate) else { return false }
            return (GeoBounds(region: region)?.contains(coordinate) ?? false)
        }

        guard !visible.isEmpty else { return [] }
        if visible.count <= target.upperBound {
            return visible.map { PhotoCluster(id: "item-\($0.id)", coordinate: $0.coordinate!, items: [$0]) }
        }

        let padded = paddedBounds(region: region, margin: margin)
        let latSpan = max(padded.maxLatitude - padded.minLatitude, 1e-6)
        let lonSpan = max(padded.maxLongitude - padded.minLongitude, 1e-6)

        var bestN = 4
        var bestScore = Int.max
        var chosenN: Int?
        for n in 4...32 {
            let count = bucketCount(visible, bounds: padded, n: n, latSpan: latSpan, lonSpan: lonSpan)
            if target.contains(count) {
                chosenN = n
                break
            }
            let score = count < target.lowerBound
                ? target.lowerBound - count
                : count - target.upperBound
            if score < bestScore {
                bestScore = score
                bestN = n
            }
        }

        let n = chosenN ?? bestN
        var buckets: [Int: [MediaItem]] = [:]
        for item in visible {
            guard let coordinate = item.coordinate else { continue }
            let x = gridIndex(coordinate.longitude, min: padded.minLongitude, span: lonSpan, n: n)
            let y = gridIndex(coordinate.latitude, min: padded.minLatitude, span: latSpan, n: n)
            buckets[y * n + x, default: []].append(item)
        }

        return buckets.map { key, bucket in
            let coordinates = bucket.compactMap { $0.coordinate }
            let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(max(coordinates.count, 1))
            let longitude = coordinates.map(\.longitude).reduce(0, +) / Double(max(coordinates.count, 1))
            return PhotoCluster(
                id: "grid-\(n)-\(key)",
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                items: bucket
            )
        }
        .sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.id < rhs.id : lhs.count > rhs.count
        }
    }

    /// Number of occupied cells for a candidate grid size. Used by tests and
    /// the adaptive selection above.
    static func clusterCount(
        items: [MediaItem],
        region: MKCoordinateRegion,
        gridSize n: Int,
        margin: Double = 0.15
    ) -> Int {
        let visible = items.filter { item in
            guard let coordinate = item.coordinate, isValid(coordinate) else { return false }
            return (GeoBounds(region: region)?.contains(coordinate) ?? false)
        }
        guard !visible.isEmpty else { return 0 }
        if visible.count <= defaultTarget.upperBound { return visible.count }
        let padded = paddedBounds(region: region, margin: margin)
        return bucketCount(
            visible,
            bounds: padded,
            n: n,
            latSpan: max(padded.maxLatitude - padded.minLatitude, 1e-6),
            lonSpan: max(padded.maxLongitude - padded.minLongitude, 1e-6)
        )
    }

    /// First, middle and last photo by capture time (ties by id). Fewer than
    /// three photos are returned as-is. These are the map card representatives.
    static func representatives(from items: [MediaItem], limit: Int = 3) -> [MediaItem] {
        let sorted = items.sorted { lhs, rhs in
            let l = lhs.creationDate ?? .distantPast
            let r = rhs.creationDate ?? .distantPast
            return l == r ? lhs.id < rhs.id : l < r
        }
        guard sorted.count > limit else { return sorted }
        let indices = [0, sorted.count / 2, sorted.count - 1]
        var seen = Set<Int>()
        return indices.compactMap { index in
            seen.insert(index).inserted ? sorted[index] : nil
        }
    }

    /// Region that fits every coordinate, with a small margin. Used when
    /// tapping a multi-photo cluster.
    static func fittingRegion(for items: [MediaItem], minimumSpan: Double = 0.002) -> MKCoordinateRegion? {
        let coordinates = items.compactMap(\.coordinate).filter(isValid)
        guard !coordinates.isEmpty else { return nil }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let latSpan = min(max((maxLat - minLat) * 1.4, minimumSpan), 170)
        let lonSpan = min(max((maxLon - minLon) * 1.4, minimumSpan), 359)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        )
    }

    private static func paddedBounds(region: MKCoordinateRegion, margin: Double) -> GeoBounds {
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        let latPad = max(halfLat * margin, 1e-6)
        let lonPad = max(halfLon * margin, 1e-6)
        return GeoBounds(
            minLatitude: region.center.latitude - halfLat - latPad,
            maxLatitude: region.center.latitude + halfLat + latPad,
            minLongitude: region.center.longitude - halfLon - lonPad,
            maxLongitude: region.center.longitude + halfLon + lonPad
        )
    }

    private static func bucketCount(
        _ items: [MediaItem],
        bounds: GeoBounds,
        n: Int,
        latSpan: Double,
        lonSpan: Double
    ) -> Int {
        var keys = Set<Int>()
        keys.reserveCapacity(items.count)
        for item in items {
            guard let coordinate = item.coordinate else { continue }
            let x = gridIndex(coordinate.longitude, min: bounds.minLongitude, span: lonSpan, n: n)
            let y = gridIndex(coordinate.latitude, min: bounds.minLatitude, span: latSpan, n: n)
            keys.insert(y * n + x)
        }
        return keys.count
    }

    private static func gridIndex(_ value: Double, min minimum: Double, span: Double, n: Int) -> Int {
        let raw = Int(((value - minimum) / span) * Double(n))
        return min(max(raw, 0), n - 1)
    }

    private static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude != 0 || coordinate.longitude != 0
    }
}
