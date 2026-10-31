import Combine
import CoreData
import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var items: [MediaItem] = []
    @Published var groupedItems: [MediaGroup] = []
    @Published var groupingMode: GroupingMode = .date
    @Published var zoomLevel: Double = 1.0
    @Published var isScanning = false
    @Published var scanProgress: String = ""
    @Published var scanFraction: Double?
    @Published var selectedItem: MediaItem?
    @Published var errorMessage: String?
    @Published var totalItemCount: Int = 0
    @Published private(set) var effectiveZoomLevel: Double = 1.0

    private(set) var persistence: PersistenceController?
    private var cancellables = Set<AnyCancellable>()
    private let batchSize = 1000
    private var currentBatchOffset = 0

    private var scanTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchAnchor: Int?
    private var indexByID: [String: Int] = [:]
    private var locationIndices: [LocationKey: [Int]] = [:]

    private let collapsedGroupDefaultsKey = "collapsedGroupIDsByMode"
    private var collapsedGroupIDsByMode: [String: Set<String>] = [:]

    var canLoadMore: Bool {
        items.count < totalItemCount
    }

    init() {
        collapsedGroupIDsByMode = loadCollapsedGroupIDs()

        $zoomLevel
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] zoom in
                self?.effectiveZoomLevel = zoom
            }
            .store(in: &cancellables)

        $items
            .combineLatest($groupingMode, $effectiveZoomLevel)
            .sink { [weak self] items, mode, zoom in
                self?.groupedItems = Self.group(
                    items: items,
                    mode: mode,
                    zoom: zoom,
                    collapsedIDs: self?.collapsedGroupIDs(for: mode) ?? []
                )
            }
            .store(in: &cancellables)
    }

    func loadStoredRoot() {
        do {
            let url = try BookmarkStore.shared.loadRootURL()
            rootURL = url
            startScan(for: url)
        } catch {
            // No stored bookmark or stale bookmark; show selector.
            rootURL = nil
        }
    }

    func setRootURL(_ url: URL) {
        cancelWork()
        rootURL = url
        items = []
        groupedItems = []
        totalItemCount = 0
        selectedItem = nil
        scanProgress = ""
        try? BookmarkStore.shared.saveBookmark(for: url)
        startScan(for: url)
    }

    func refresh() async {
        guard let rootURL else { return }
        cancelWork()
        let task = Task { await self.performScan(rootURL: rootURL) }
        scanTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelWork() {
        scanTask?.cancel()
        maintenanceTask?.cancel()
        prefetchTask?.cancel()
        scanTask = nil
        maintenanceTask = nil
        prefetchTask = nil
    }

    private func startScan(for url: URL) {
        scanTask?.cancel()
        scanTask = Task { await self.setupLibrary(for: url) }
    }

    func loadMoreItems() async {
        guard canLoadMore else { return }
        currentBatchOffset += batchSize
        await fetchBatch(offset: currentBatchOffset)
    }

    private func setupLibrary(for url: URL) async {
        do {
            let storeURL = PersistenceController.storeURL(for: url)
            persistence = try PersistenceController(storeURL: storeURL)
            await performScan(rootURL: url)
        } catch is CancellationError {
            scanProgress = "Cancelled"
        } catch {
            errorMessage = "Failed to open library: \(error.localizedDescription)"
        }
    }

    private func performScan(rootURL: URL) async {
        isScanning = true
        scanProgress = "Scanning…"
        scanFraction = nil
        defer { isScanning = false }

        guard let persistence else { return }

        do {
            let result = try await rootURL.withSecurityScope {
                let backgroundContext = persistence.container.newBackgroundContext()
                let scanner = MediaScanner(context: backgroundContext)
                return try await scanner.scan(rootURL: rootURL)
            }

            // Publish the grid as soon as the index is ready. Thumbnails are
            // generated on demand by the grid, and geocoding runs afterwards.
            await fetchItems()
            scanProgress = "Indexed \(result.processed) new/changed items, \(totalItemCount) total."
            startMaintenance(rootURL: rootURL)
        } catch is CancellationError {
            scanProgress = "Cancelled"
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
    }

    /// Post-scan work that must not delay the first screen: thumbnail cleanup
    /// and reverse geocoding. Both update the UI incrementally as results arrive.
    private func startMaintenance(rootURL: URL) {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            guard let self else { return }
            await self.purgeOrphanedThumbnails(rootURL: rootURL)
            guard !Task.isCancelled else { return }
            await self.geocodeLocations(rootURL: rootURL)
        }
    }

    private func purgeOrphanedThumbnails(rootURL: URL) async {
        guard let persistence else { return }
        let context = persistence.container.newBackgroundContext()
        let validInputs = await context.perform {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            let items = (try? context.fetch(request)) ?? []
            return items.map {
                ThumbnailInput(
                    relativePath: $0.relativePath,
                    modificationDate: $0.contentModificationDate,
                    mediaType: $0.mediaType
                )
            }
        }
        guard !Task.isCancelled else { return }
        await rootURL.withSecurityScope {
            await ThumbnailGenerator.shared.purgeOrphanedThumbnails(rootURL: rootURL, validInputs: validInputs)
        }
    }

    private func geocodeLocations(rootURL: URL) async {
        guard let persistence else { return }
        let context = persistence.container.newBackgroundContext()
        await GeocoderService.shared.geocodeUncachedCoordinates(in: context) { [weak self] resolved in
            await self?.applyLocationName(resolved)
        }
    }

    private func applyLocationName(_ resolved: GeocodedLocation) {
        let key = LocationKey(latitude: resolved.latitude, longitude: resolved.longitude)
        guard let indices = locationIndices[key], !indices.isEmpty else { return }
        for index in indices where items.indices.contains(index) {
            items[index] = items[index].withLocationName(resolved.name)
        }
    }

    /// Warm the thumbnail cache for items around the visible cell.
    func prefetchThumbnails(around item: MediaItem) {
        guard let rootURL, let index = indexByID[item.id] else { return }
        if let anchor = prefetchAnchor, abs(anchor - index) < 8 { return }
        prefetchAnchor = index

        let lower = max(0, index - 4)
        let upper = min(items.count, index + 24)
        guard lower < upper else { return }
        let inputs = items[lower..<upper].map {
            ThumbnailInput(
                relativePath: $0.relativePath,
                modificationDate: $0.contentModificationDate,
                mediaType: $0.mediaType
            )
        }

        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .utility) {
            for input in inputs {
                if Task.isCancelled { return }
                _ = await ThumbnailGenerator.shared.thumbnail(for: input, rootURL: rootURL)
            }
        }
    }

    private func fetchItems() async {
        guard let persistence else { return }
        currentBatchOffset = 0
        items = []
        indexByID = [:]
        locationIndices = [:]
        prefetchAnchor = nil

        let context = persistence.container.viewContext
        let countRequest = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
        countRequest.resultType = .countResultType

        do {
            let count = try await context.perform {
                try context.count(for: countRequest)
            }
            totalItemCount = count
        } catch {
            errorMessage = "Failed to count items: \(error.localizedDescription)"
            return
        }

        await fetchBatch(offset: 0)
    }

    private func fetchBatch(offset: Int) async {
        guard let persistence else { return }
        let context = persistence.container.viewContext
        let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        request.fetchOffset = offset
        request.fetchLimit = batchSize

        do {
            let entities = try await context.perform {
                try context.fetch(request)
            }
            let newItems = entities.map { entity in
                MediaItem(
                    id: entity.relativePath,
                    relativePath: entity.relativePath,
                    fileName: entity.fileName,
                    fileSize: entity.fileSize,
                    contentModificationDate: entity.contentModificationDate,
                    creationDate: entity.creationDate,
                    coordinate: entity.coordinate,
                    locationName: entity.locationName,
                    mediaType: entity.mediaType,
                    thumbnailPath: entity.thumbnailPath
                )
            }
            items.append(contentsOf: newItems)
            indexAppendedItems(from: items.count - newItems.count, to: items.count)
        } catch {
            errorMessage = "Failed to load items: \(error.localizedDescription)"
        }
    }

    private func indexAppendedItems(from lowerBound: Int, to upperBound: Int) {
        guard lowerBound < upperBound else { return }
        for index in lowerBound..<upperBound {
            let item = items[index]
            indexByID[item.id] = index
            guard let coordinate = item.coordinate else { continue }
            let key = LocationKey(latitude: coordinate.latitude, longitude: coordinate.longitude)
            locationIndices[key, default: []].append(index)
        }
    }

    // MARK: - Grouping

    func toggleCollapsed(for group: MediaGroup) {
        let mode = groupingMode
        var ids = collapsedGroupIDs(for: mode)
        if ids.contains(group.id) {
            ids.remove(group.id)
        } else {
            ids.insert(group.id)
        }
        collapsedGroupIDsByMode[mode.rawValue] = ids
        saveCollapsedGroupIDs()

        groupedItems = Self.group(
            items: items,
            mode: mode,
            zoom: effectiveZoomLevel,
            collapsedIDs: ids
        )
    }

    private func collapsedGroupIDs(for mode: GroupingMode) -> Set<String> {
        collapsedGroupIDsByMode[mode.rawValue] ?? []
    }

    private func loadCollapsedGroupIDs() -> [String: Set<String>] {
        guard let data = UserDefaults.standard.data(forKey: collapsedGroupDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded.mapValues { Set($0) }
    }

    private func saveCollapsedGroupIDs() {
        let encodable = collapsedGroupIDsByMode.mapValues { Array($0) }
        if let data = try? JSONEncoder().encode(encodable) {
            UserDefaults.standard.set(data, forKey: collapsedGroupDefaultsKey)
        }
    }

    private static func group(items: [MediaItem], mode: GroupingMode, zoom: Double, collapsedIDs: Set<String>) -> [MediaGroup] {
        switch mode {
        case .none:
            return [MediaGroup(id: "all", title: "All Media", items: items)]
        case .date:
            return groupByDate(items: items, zoom: zoom, collapsedIDs: collapsedIDs)
        case .location:
            return groupByLocation(items: items, collapsedIDs: collapsedIDs)
        }
    }

    private static func groupByDate(items: [MediaItem], zoom: Double, collapsedIDs: Set<String>) -> [MediaGroup] {
        let calendar = Calendar.current
        let granularity: DateGranularity = {
            if zoom > 1.2 { return .day }
            if zoom >= 0.7 { return .month }
            return .year
        }()

        var buckets: [String: [MediaItem]] = [:]
        for item in items {
            guard let date = item.creationDate else {
                buckets["Unknown Date", default: []].append(item)
                continue
            }
            let key = dateKey(date: date, granularity: granularity, calendar: calendar)
            buckets[key, default: []].append(item)
        }

        let sortedKeys = buckets.keys.sorted { a, b in
            if a == "Unknown Date" { return false }
            if b == "Unknown Date" { return true }
            return a > b
        }

        return sortedKeys.map { key in
            MediaGroup(id: key, title: key, items: buckets[key] ?? [], isCollapsed: collapsedIDs.contains(key))
        }
    }

    private static func groupByLocation(items: [MediaItem], collapsedIDs: Set<String>) -> [MediaGroup] {
        var buckets: [String: [MediaItem]] = [:]
        for item in items {
            let key = item.locationName?.isEmpty == false ? item.locationName! : "Unknown Location"
            buckets[key, default: []].append(item)
        }
        let sortedKeys = buckets.keys.sorted()
        return sortedKeys.map { key in
            MediaGroup(id: key, title: key, items: buckets[key] ?? [], isCollapsed: collapsedIDs.contains(key))
        }
    }

    private static func dateKey(date: Date, granularity: DateGranularity, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch granularity {
        case .year:
            formatter.dateFormat = "yyyy"
        case .month:
            formatter.dateFormat = "yyyy-MM"
        case .day:
            formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }

    private enum DateGranularity {
        case year, month, day
    }
}
