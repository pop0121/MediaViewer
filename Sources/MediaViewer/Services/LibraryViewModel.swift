import Combine
import CoreData
import Foundation
import MapKit
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var items: [MediaItem] = []
    @Published var groupedItems: [MediaGroup] = []
    @Published var groupingMode: GroupingMode = .months
    @Published private(set) var timeFocus: TimeAnchor?
    @Published private(set) var scrollTarget: TimeScrollTarget?
    @Published private(set) var clusterSelection: Set<String>?
    @Published private(set) var clusterLabel: String?
    @Published var lastMapRegion: MKCoordinateRegion?
    @Published var regionFilter: GeoBounds?
    @Published var gridDensity: Double = 1.0
    @Published var isScanning = false
    @Published var scanProgress: String = ""
    @Published var scanFraction: Double?
    @Published var isFastScrolling = false
    @Published var selectedItem: MediaItem?
    @Published var errorMessage: String?
    @Published var totalItemCount: Int = 0
    @Published private(set) var effectiveDensity: Double = 1.0

    static let densityRange: ClosedRange<Double> = 0.5...2.0
    static let densityPresets: [Double] = [0.5, 0.7, 1.0, 1.4, 2.0]
    static func clampDensity(_ value: Double) -> Double {
        min(max(value, densityRange.lowerBound), densityRange.upperBound)
    }
    var zoomLevel: Double {
        get { gridDensity }
        set { setDensity(newValue) }
    }
    var effectiveZoomLevel: Double { effectiveDensity }
    /// Incremented whenever `groupedItems` is recomputed. Used by behavior tests
    /// to prove zoom changes do not regroup.
    private(set) var regroupCount = 0
    /// Number of viewport-driven breadcrumb changes. Tests use this to prove
    /// scrolling across a month boundary updates once, without regrouping.
    private(set) var timeFollowCount = 0
    /// Model-side landing request latency, in milliseconds.
    private(set) var lastLandingRequestMS: Double = 0
    private var scrollTargetToken = 0

    private(set) var persistence: PersistenceController?
    private var cancellables = Set<AnyCancellable>()
    private let batchSize = 1000
    private var currentBatchOffset = 0

    private var scanTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchAnchor: Int?
    private var prefetchStartIndex: Int?
    private var prefetchStartTier: ThumbnailTier?
    private var prefetchTier: ThumbnailTier = .grid
    /// Normal browsing prefetches a broad window; a fling only needs the
    /// visible row plus two screens of headroom.
    private static let prefetchRadius = 48
    private static let fastPrefetchRadius = 24
    /// Test/debug switch for measuring first-screen fill with and without the
    /// look-ahead prefetcher.
    var prefetchEnabled = true
    private var indexByID: [String: Int] = [:]
    private var locationIndices: [LocationKey: [Int]] = [:]
    private var dateKeyCache: [String: DateKeys] = [:]
    /// Topmost section inferred from the grid's scroll position; consumed when
    /// the user changes granularity.
    private(set) var topAnchor: TimeAnchor?

    private let collapsedGroupDefaultsKey = "collapsedGroupIDsByMode"
    private var collapsedGroupIDsByMode: [String: Set<String>] = [:]

    var canLoadMore: Bool {
        !isScanning && items.count < totalItemCount
    }

    var itemsWithoutLocationCount: Int {
        items.reduce(0) { count, item in
            guard let coordinate = item.coordinate,
                  coordinate.latitude != 0 || coordinate.longitude != 0 else {
                return count + 1
            }
            return count
        }
    }

    init() {
        collapsedGroupIDsByMode = loadCollapsedGroupIDs()

        $gridDensity
            .map { Self.clampDensity($0) }
            .removeDuplicates()
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)
            .sink { [weak self] density in
                self?.effectiveDensity = density
            }
            .store(in: &cancellables)

        $items
            .combineLatest($groupingMode, $regionFilter, $clusterSelection)
            .sink { [weak self] items, mode, regionFilter, clusterSelection in
                guard let self else { return }
                self.regroupCount += 1
                var scoped = items
                if let clusterSelection {
                    scoped = scoped.filter { clusterSelection.contains($0.id) }
                } else if let regionFilter {
                    scoped = scoped.filter { item in
                        guard let coordinate = item.coordinate else { return false }
                        return regionFilter.contains(coordinate)
                    }
                }
                // Time focus is a viewport anchor, never a hard filter: the
                // grouped timeline stays complete.
                self.groupedItems = self.group(
                    items: scoped,
                    mode: mode,
                    collapsedIDs: self.collapsedGroupIDs(for: mode)
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
        // Appending 1,000 rows while a fling is in flight would force a full
        // canvas rebuild mid-gesture. The canvas re-arms and retries after the
        // fling settles; the fetch itself runs on a private queue.
        guard canLoadMore, !isFastScrolling else { return }
        currentBatchOffset += batchSize
        await fetchBatch(offset: currentBatchOffset)
    }

    /// Load every page for the Places map. The grid stays paged; the map needs
    /// all coordinates to cluster the full library.
    func loadAllItems() async {
        guard !isScanning else { return }
        while canLoadMore && !Task.isCancelled {
            await loadMoreItems()
        }
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
            let scanInterval = Perf.begin("scan.total")
            let result = try await rootURL.withSecurityScope {
                let backgroundContext = persistence.container.newBackgroundContext()
                let scanner = MediaScanner(context: backgroundContext)
                return try await scanner.scan(
                    rootURL: rootURL,
                    progress: { [weak self] progress in
                        await self?.updateScanProgress(progress)
                    },
                    indexed: { [weak self] items in
                        await self?.mergeIndexedItems(items)
                    }
                )
            }
            Perf.end(scanInterval, "processed=\(result.processed) removed=\(result.removed)")

            // Publish the grid as soon as the index is ready. Thumbnails are
            // generated on demand by the grid, and geocoding runs afterwards.
            let fetchInterval = Perf.begin("library.firstScreenFetch")
            await fetchItems()
            Perf.end(fetchInterval, "total=\(totalItemCount)")
            scanProgress = "Indexed \(result.processed) new/changed items, \(totalItemCount) total."
            startMaintenance(rootURL: rootURL)
        } catch is CancellationError {
            scanProgress = "Cancelled"
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
    }

    /// Append or refresh items that the scanner has already committed. This
    /// runs while scanning, so the grid does not wait for the full index.
    private func mergeIndexedItems(_ newItems: [MediaItem]) {
        guard !newItems.isEmpty else { return }
        // Mutate a local copy and publish once per batch; appending directly to
        // the @Published array would re-group the whole library once per item.
        var updated = items
        var changed = false
        for item in newItems {
            if let index = indexByID[item.id] {
                let existing = updated[index]
                if existing.contentModificationDate != item.contentModificationDate
                    || existing.creationDate != item.creationDate
                    || existing.locationName != item.locationName {
                    updated[index] = item
                    dateKeyCache.removeValue(forKey: item.id)
                    changed = true
                }
            } else {
                updated.append(item)
                indexByID[item.id] = updated.count - 1
                changed = true
            }
        }
        guard changed else { return }
        items = updated
        rebuildIndices()
        prefetchAnchor = nil
        prefetchStartIndex = nil
        prefetchStartTier = nil
    }

    private func updateScanProgress(_ progress: ScanProgress) {
        switch progress.phase {
        case .enumerating:
            scanProgress = "Scanning… \(progress.completed) files found"
            scanFraction = nil
        case .indexing:
            scanProgress = "Indexing \(progress.completed) of \(progress.total)…"
            scanFraction = progress.total > 0
                ? Double(progress.completed) / Double(progress.total)
                : nil
        case .saving:
            scanProgress = "Saving index…"
            scanFraction = 1
        }
    }

    /// Cancel the current scan. Partial results are kept; the next scan resumes.
    func cancelScan() {
        cancelWork()
        scanProgress = "Cancelling…"
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
        let interval = Perf.begin("maintenance.purgeThumbnails")
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
        Perf.end(interval, "valid=\(validInputs.count)")
    }

    private func geocodeLocations(rootURL: URL) async {
        guard let persistence else { return }
        let interval = Perf.begin("maintenance.geocode")
        let context = persistence.container.newBackgroundContext()
        await GeocoderService.shared.geocodeUncachedCoordinates(in: context) { [weak self] resolved in
            await self?.applyLocationName(resolved)
        }
        Perf.end(interval)
    }

    private func applyLocationName(_ resolved: GeocodedLocation) {
        let key = LocationKey(latitude: resolved.latitude, longitude: resolved.longitude)
        guard let indices = locationIndices[key], !indices.isEmpty else { return }
        for index in indices where items.indices.contains(index) {
            items[index] = items[index].withLocationName(resolved.name)
        }
    }

    /// Track fast scrolling; pause prefetch/generation while flinging and
    /// resume around the latest visible item once scrolling settles.
    func setFastScrolling(_ fast: Bool) {
        guard fast != isFastScrolling else { return }
        isFastScrolling = fast
        if fast {
            prefetchTask?.cancel()
            prefetchTask = nil
        } else if let anchor = prefetchAnchor {
            // A fling only leaves a two-screen window warm. Once the user keeps
            // browsing, the next visible cell widens the window to ±48.
            startPrefetch(around: anchor,
                          tier: prefetchTier,
                          radius: Self.fastPrefetchRadius)
        }
    }

    func setDensity(_ value: Double) {
        let clamped = Self.clampDensity(value)
        if gridDensity != clamped {
            gridDensity = clamped
        }
    }

    func adjustDensity(by delta: Double) {
        setDensity(gridDensity + delta)
    }

    /// Warm the thumbnail cache for items around the visible cell.
    func prefetchThumbnails(around item: MediaItem, tier: ThumbnailTier = .grid) {
        guard prefetchEnabled else { return }
        guard let index = indexByID[item.id] else { return }
        prefetchAnchor = index
        prefetchTier = tier
        guard !isFastScrolling else { return }
        if prefetchStartTier == tier, let lastStart = prefetchStartIndex, abs(lastStart - index) < 8 {
            return
        }
        startPrefetch(around: index,
                      tier: tier,
                      radius: Self.prefetchRadius)
    }

    private func startPrefetch(around index: Int,
                               tier: ThumbnailTier,
                               radius: Int) {
        guard let rootURL else { return }
        prefetchStartIndex = index
        prefetchStartTier = tier
        let lower = max(0, index - radius)
        let upper = min(items.count, index + radius + 1)
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
                _ = await ThumbnailGenerator.shared.thumbnail(for: input,
                                                             tier: tier,
                                                             rootURL: rootURL,
                                                             priority: .utility)
            }
        }
    }

    private func fetchItems() async {
        guard let persistence else { return }
        currentBatchOffset = 0

        let context = persistence.container.newBackgroundContext()

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

        guard let firstPage = await fetchBatchItems(offset: 0) else { return }
        items = firstPage
        dateKeyCache = [:]
        prefetchAnchor = nil
        prefetchStartIndex = nil
        prefetchStartTier = nil
        rebuildIndices()
    }

    private func fetchBatch(offset: Int) async {
        guard let newItems = await fetchBatchItems(offset: offset) else { return }
        items.append(contentsOf: newItems)
        indexAppendedItems(from: items.count - newItems.count, to: items.count)
    }

    private func fetchBatchItems(offset: Int) async -> [MediaItem]? {
        guard let persistence else { return nil }
        // Fetch and convert on a private queue. Doing this on the view context
        // made the first 1,000-row page a main-thread hitch when paging.
        let context = persistence.container.newBackgroundContext()
        let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
        request.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        request.fetchOffset = offset
        request.fetchLimit = batchSize

        do {
            return try await context.perform {
                try context.fetch(request).map(MediaItem.init(entity:))
            }
        } catch {
            errorMessage = "Failed to load items: \(error.localizedDescription)"
            return nil
        }
    }

    private func rebuildIndices() {
        indexByID.removeAll(keepingCapacity: true)
        locationIndices.removeAll(keepingCapacity: true)
        indexAppendedItems(from: 0, to: items.count)
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

    // MARK: - Time drill-down

    var hasTimeFocus: Bool { timeFocus != nil }

    var breadcrumbItems: [TimeBreadcrumbItem] {
        var items = [TimeBreadcrumbItem(level: .all, title: "All")]
        guard let focus = timeFocus else { return items }
        items.append(TimeBreadcrumbItem(level: .year(focus.year), title: String(focus.year)))
        if let monthTitle = focus.monthTitle {
            items.append(TimeBreadcrumbItem(level: .month(focus.year, focus.month!), title: monthTitle))
        }
        return items
    }

    /// Feed the topmost visible section from the grid's geometry observer.
    /// The section updates the breadcrumb/segment anchor only; it never regroups
    /// and never changes the scroll target, so scrolling remains uninterrupted.
    func updateTopSection(_ groupID: String?) {
        let anchor = groupID.flatMap(TimeAnchor.init(groupID:))
        guard anchor != topAnchor else { return }
        topAnchor = anchor
        guard groupingMode != .all,
              groupingMode != .location,
              clusterSelection == nil else { return }

        let focus: TimeAnchor?
        switch groupingMode {
        case .years:
            focus = anchor.map { TimeAnchor(year: $0.year) }
        case .months, .days:
            focus = anchor.map { TimeAnchor(year: $0.year, month: $0.month) }
        case .all, .location:
            focus = nil
        }
        if focus != timeFocus {
            timeFocus = focus
            timeFollowCount += 1
        }
    }

    /// Change granularity while carrying the current anchor forward. The full
    /// timeline is retained; the UI scrolls the anchor section to the top.
    func selectGranularity(_ mode: GroupingMode) {
        if clusterSelection != nil {
            clusterSelection = nil
            clusterLabel = nil
        }
        guard mode != groupingMode else { return }
        let base = topAnchor ?? timeFocus

        groupingMode = mode
        topAnchor = nil
        scrollTarget = nil

        switch mode {
        case .all, .location:
            timeFocus = nil
        case .years:
            guard let base else { timeFocus = nil; return }
            let anchor = TimeAnchor(year: base.year)
            timeFocus = anchor
            requestLanding(on: .years, anchor: anchor)
        case .months:
            guard let base else { timeFocus = nil; return }
            let anchor = TimeAnchor(year: base.year, month: base.month)
            timeFocus = anchor
            requestLanding(on: .months, anchor: anchor)
        case .days:
            guard let base else { timeFocus = nil; return }
            timeFocus = TimeAnchor(year: base.year, month: base.month)
            requestLanding(on: .days, anchor: base)
        }
    }

    private func requestLanding(on mode: GroupingMode, anchor: TimeAnchor) {
        let start = CFAbsoluteTimeGetCurrent()
        defer { lastLandingRequestMS = (CFAbsoluteTimeGetCurrent() - start) * 1000 }
        guard let groupID = landingGroupID(mode: mode, anchor: anchor) else { return }
        scrollTargetToken += 1
        scrollTarget = TimeScrollTarget(groupID: groupID, token: scrollTargetToken)
    }

    private func landingGroupID(mode: GroupingMode, anchor: TimeAnchor) -> String? {
        let ids = Set(groupedItems.map(\.id))
        switch mode {
        case .years:
            let id = String(format: "%04d", anchor.year)
            return ids.contains(id) ? id : nil
        case .months:
            if let month = anchor.month {
                let id = String(format: "%04d-%02d", anchor.year, month)
                if ids.contains(id) { return id }
            }
            return groupedItems.first { $0.id.hasPrefix(String(format: "%04d-", anchor.year)) }?.id
        case .days:
            if let month = anchor.month, let day = anchor.day {
                let id = String(format: "%04d-%02d-%02d", anchor.year, month, day)
                if ids.contains(id) { return id }
            }
            if let month = anchor.month {
                let prefix = String(format: "%04d-%02d-", anchor.year, month)
                if let id = groupedItems.first(where: { $0.id.hasPrefix(prefix) })?.id {
                    return id
                }
            }
            let prefix = String(format: "%04d-", anchor.year)
            return groupedItems.first { $0.id.hasPrefix(prefix) }?.id
        case .all, .location:
            return nil
        }
    }

    /// Pop one breadcrumb level: month -> year, year -> full timeline.
    func goBackOneLevel() {
        guard let focus = timeFocus else { return }
        if focus.month != nil {
            let anchor = TimeAnchor(year: focus.year)
            groupingMode = .years
            timeFocus = anchor
            topAnchor = anchor
            requestLanding(on: .years, anchor: anchor)
        } else {
            showAllTimeline()
        }
    }

    func focus(on level: TimeBreadcrumbItem.Level) {
        clusterSelection = nil
        clusterLabel = nil
        topAnchor = nil
        scrollTarget = nil
        switch level {
        case .all:
            showAllTimeline()
        case .year(let year):
            let anchor = TimeAnchor(year: year)
            groupingMode = .years
            timeFocus = anchor
            topAnchor = anchor
            requestLanding(on: .years, anchor: anchor)
        case .month(let year, let month):
            let anchor = TimeAnchor(year: year, month: month)
            groupingMode = .months
            timeFocus = anchor
            topAnchor = anchor
            requestLanding(on: .months, anchor: anchor)
        }
    }

    func showAllTimeline() {
        timeFocus = nil
        topAnchor = nil
        scrollTarget = nil
        clusterSelection = nil
        clusterLabel = nil
        groupingMode = .all
    }

    /// Open the grid scoped to one map cluster. The set is a snapshot so the
    /// grid stays stable while the user navigates.
    func showClusterGrid(cluster: PhotoCluster) {
        clusterSelection = Set(cluster.items.map(\.id))
        clusterLabel = "\(cluster.count) photos"
        regionFilter = nil
        timeFocus = nil
        topAnchor = nil
        scrollTarget = nil
        groupingMode = .months
    }

    /// Return to the map, preserving `lastMapRegion` and therefore the same
    /// viewport/cluster layout the user came from.
    func backToMap() {
        clusterSelection = nil
        clusterLabel = nil
        regionFilter = nil
        timeFocus = nil
        topAnchor = nil
        scrollTarget = nil
        groupingMode = .location
    }

    /// Switch to a grid grouped by month, restricted to the map's current area.
    func showGrid(in region: MKCoordinateRegion) {
        guard let bounds = GeoBounds(region: region) else { return }
        clusterSelection = nil
        clusterLabel = nil
        timeFocus = nil
        topAnchor = nil
        scrollTarget = nil
        groupingMode = .months
        regionFilter = bounds
    }

    func clearRegionFilter() {
        regionFilter = nil
    }

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

        groupedItems = self.group(
            items: items,
            mode: mode,
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

    private func group(items: [MediaItem], mode: GroupingMode, collapsedIDs: Set<String>) -> [MediaGroup] {
        switch mode {
        case .all:
            return [MediaGroup(id: "all", title: "All Media", items: items)]
        case .years, .months, .days:
            return groupByDate(items: items, mode: mode, collapsedIDs: collapsedIDs)
        case .location:
            return groupByLocation(items: items, collapsedIDs: collapsedIDs)
        }
    }

    private func groupByDate(items: [MediaItem], mode: GroupingMode, collapsedIDs: Set<String>) -> [MediaGroup] {
        let calendar = Calendar.current

        var buckets: [String: [MediaItem]] = [:]
        for item in items {
            guard let date = item.creationDate else {
                buckets["Unknown Date", default: []].append(item)
                continue
            }
            let keys = dateKeys(for: item, date: date, calendar: calendar)
            let key: String
            switch mode {
            case .years: key = keys.year
            case .months: key = keys.month
            case .days: key = keys.day
            case .all, .location: continue
            }
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

    private func groupByLocation(items: [MediaItem], collapsedIDs: Set<String>) -> [MediaGroup] {
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

    /// Date group keys are computed once per item and reused for every regroup.
    private func dateKeys(for item: MediaItem, date: Date, calendar: Calendar) -> DateKeys {
        if let cached = dateKeyCache[item.id] {
            return cached
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", components.year ?? 0)
        let month = String(format: "%@-%02d", year, components.month ?? 0)
        let day = String(format: "%@-%02d", month, components.day ?? 0)
        let keys = DateKeys(year: year, month: month, day: day)
        dateKeyCache[item.id] = keys
        return keys
    }

    private struct DateKeys {
        let year: String
        let month: String
        let day: String
    }

}
