import AppKit
import MapKit
import SwiftUI

/// MapKit-backed Places view. Clustering is local; no tiles API key or
/// third-party service is used beyond Apple's MapKit.
struct PlacesMapView: NSViewRepresentable {
    let items: [MediaItem]
    let onOpen: (MediaItem) -> Void
    let onRegionChange: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.register(PhotoClusterAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: PhotoClusterAnnotationView.reuseIdentifier)
        if #available(macOS 13.0, *) {
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = configuration
        }
        context.coordinator.mapView = mapView
        context.coordinator.update(items: items, resetRegion: true)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(items: items, resetRegion: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PlacesMapView
        weak var mapView: MKMapView?
        private var items: [MediaItem] = []
        private var signature: Int = 0
        private var pendingRefresh: DispatchWorkItem?
        private var hasUserInteracted = false
        private var suppressRegionUntil: CFAbsoluteTime = 0

        init(parent: PlacesMapView) {
            self.parent = parent
        }

        func update(items: [MediaItem], resetRegion: Bool) {
            let newSignature = Self.signature(for: items)
            if !resetRegion && newSignature == signature { return }
            let previousCount = self.items.count
            self.items = items
            signature = newSignature

            guard let mapView else { return }
            if resetRegion || (!hasUserInteracted && items.count != previousCount) {
                let region = Self.initialRegion(for: items)
                suppressRegionUntil = CFAbsoluteTimeGetCurrent() + 0.3
                mapView.setRegion(region, animated: false)
                refreshClusters(region: region)
            } else {
                refreshClusters(region: mapView.region)
            }
        }

        private func scheduleRefresh() {
            pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let mapView = self.mapView else { return }
                self.refreshClusters(region: mapView.region)
            }
            pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func refreshClusters(region: MKCoordinateRegion) {
            guard let mapView else { return }
            let clusters = PlacesClusterer.clusters(items: items, region: region)
            let annotations = clusters.map(PhotoClusterAnnotation.init)
            mapView.removeAnnotations(mapView.annotations)
            mapView.addAnnotations(annotations)

            // Defer to avoid mutating SwiftUI state during a view update.
            DispatchQueue.main.async { [weak self] in
                self?.parent.onRegionChange(region)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if CFAbsoluteTimeGetCurrent() > suppressRegionUntil {
                hasUserInteracted = true
            }
            scheduleRefresh()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let clusterAnnotation = annotation as? PhotoClusterAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: PhotoClusterAnnotationView.reuseIdentifier,
                for: clusterAnnotation
            ) as! PhotoClusterAnnotationView
            view.annotation = clusterAnnotation
            view.configure(with: clusterAnnotation.cluster)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? PhotoClusterAnnotation else { return }
            let cluster = annotation.cluster
            if cluster.count == 1, let item = cluster.items.first {
                parent.onOpen(item)
                mapView.deselectAnnotation(annotation, animated: false)
                return
            }

            if let region = PlacesClusterer.fittingRegion(for: cluster.items) {
                mapView.setRegion(region, animated: true)
            }
            mapView.deselectAnnotation(annotation, animated: false)
        }

        /// Includes IDs, coordinates and cached names so geocoding updates
        /// refresh annotation titles without resetting the map.
        private static func signature(for items: [MediaItem]) -> Int {
            var hasher = Hasher()
            hasher.combine(items.count)
            for item in items {
                hasher.combine(item.id)
                hasher.combine(item.coordinate?.latitude ?? 0)
                hasher.combine(item.coordinate?.longitude ?? 0)
                hasher.combine(item.locationName)
            }
            return hasher.finalize()
        }

        private static func initialRegion(for items: [MediaItem]) -> MKCoordinateRegion {
            let coordinates = items.compactMap(\.coordinate).filter {
                $0.latitude != 0 || $0.longitude != 0
            }
            guard !coordinates.isEmpty else {
                return MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: 34.0, longitude: 108.0),
                    span: MKCoordinateSpan(latitudeDelta: 65, longitudeDelta: 90)
                )
            }

            let lats = coordinates.map(\.latitude)
            let lons = coordinates.map(\.longitude)
            let minLat = lats.min()!, maxLat = lats.max()!
            let minLon = lons.min()!, maxLon = lons.max()!
            let latSpan = min(max((maxLat - minLat) * 1.25, 0.02), 170)
            let lonSpan = min(max((maxLon - minLon) * 1.25, 0.02), 359)
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                               longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
            )
        }
    }
}

final class PhotoClusterAnnotation: NSObject, MKAnnotation {
    let cluster: PhotoCluster
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(cluster: PhotoCluster) {
        self.cluster = cluster
        self.coordinate = cluster.coordinate
        self.title = cluster.title
        super.init()
    }

    var subtitle: String? {
        cluster.count == 1 ? nil : "\(cluster.count) photos"
    }
}

final class PhotoClusterAnnotationView: MKMarkerAnnotationView {
    static let reuseIdentifier = "PhotoClusterAnnotation"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = true
        displayPriority = .required
        collisionMode = .circle
        animatesWhenAdded = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with cluster: PhotoCluster) {
        markerTintColor = cluster.count > 1 ? .systemBlue : .systemTeal
        if cluster.count > 1 {
            glyphText = "\(cluster.count)"
            glyphImage = nil
        } else {
            glyphText = nil
            glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo")
        }
    }
}
