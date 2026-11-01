import AppKit
import SwiftUI

/// A virtualized, layer-backed grid. It deliberately avoids NSCollectionView:
/// that container re-laid out and re-created visible item views on every scroll
/// tick. Here the document is one view and only a bounded set of CALayers is
/// updated, so scrolling does no view-tree or Auto Layout work.
struct GridCollectionView: NSViewRepresentable {
    let groups: [MediaGroup]
    let rootURL: URL
    let tier: ThumbnailTier
    let minimumItemWidth: CGFloat
    let scrollTarget: TimeScrollTarget?
    let onOpen: (MediaItem) -> Void
    let onToggle: (MediaGroup) -> Void
    let onPrefetch: (MediaItem, ThumbnailTier) -> Void
    let onVisibleSection: (String?) -> Void
    let onFastScrolling: (Bool) -> Void
    let onLoadMore: () -> Void

    func makeNSView(context: Context) -> GridContainerView {
        let view = GridContainerView()
        applyCallbacks(to: view)
        view.apply(groups: groups,
                   rootURL: rootURL,
                   tier: tier,
                   minimumItemWidth: minimumItemWidth,
                   scrollTarget: scrollTarget,
                   force: true)
        return view
    }

    func updateNSView(_ nsView: GridContainerView, context: Context) {
        applyCallbacks(to: nsView)
        nsView.apply(groups: groups,
                     rootURL: rootURL,
                     tier: tier,
                     minimumItemWidth: minimumItemWidth,
                     scrollTarget: scrollTarget,
                     force: false)
    }

    private func applyCallbacks(to view: GridContainerView) {
        view.onOpen = onOpen
        view.onToggle = onToggle
        view.onPrefetch = onPrefetch
        view.onVisibleSection = onVisibleSection
        view.onFastScrolling = onFastScrolling
        view.onLoadMore = onLoadMore
    }
}

/// Geometry for the grid. All heights are computed from the data, never from
/// cell contents, so adding/removing thumbnails cannot move the scroll anchor.
struct GridCanvasLayout {
    struct Section {
        let id: String
        let groupIndex: Int
        let header: CGRect
        let contentTop: CGFloat
        let items: [CGRect]
        let height: CGFloat
    }

    let sections: [Section]
    let contentSize: NSSize
    let columns: Int
    let itemWidth: CGFloat

    static let headerHeight: CGFloat = 30
    static let interitemSpacing: CGFloat = 8
    static let lineSpacing: CGFloat = 8
    static let sideInset: CGFloat = 8
    static let bottomInset: CGFloat = 8

    init(groups: [MediaGroup], width: CGFloat, minimumItemWidth: CGFloat) {
        let width = max(width, minimumItemWidth + Self.sideInset * 2)
        let available = max(width - Self.sideInset * 2, 1)
        let columns = max(1, Int(floor((available + Self.interitemSpacing) / (minimumItemWidth + Self.interitemSpacing))))
        let itemWidth = max(1, floor((available - CGFloat(columns - 1) * Self.interitemSpacing) / CGFloat(columns)))

        var sections: [Section] = []
        sections.reserveCapacity(groups.count)
        var y: CGFloat = 0

        for (groupIndex, group) in groups.enumerated() {
            let header = CGRect(x: 0, y: y, width: width, height: Self.headerHeight)
            let contentTop = y + Self.headerHeight
            var rects: [CGRect] = []
            var sectionHeight = Self.headerHeight

            if !group.isCollapsed && !group.items.isEmpty {
                let rows = Int(ceil(Double(group.items.count) / Double(columns)))
                sectionHeight += CGFloat(rows) * itemWidth + CGFloat(max(rows - 1, 0)) * Self.lineSpacing
                sectionHeight += Self.bottomInset
                rects.reserveCapacity(group.items.count)
                for item in group.items.indices {
                    let row = item / columns
                    let column = item % columns
                    rects.append(CGRect(
                        x: Self.sideInset + CGFloat(column) * (itemWidth + Self.interitemSpacing),
                        y: contentTop + CGFloat(row) * (itemWidth + Self.lineSpacing),
                        width: itemWidth,
                        height: itemWidth
                    ))
                }
            }

            sections.append(Section(id: group.id,
                                    groupIndex: groupIndex,
                                    header: header,
                                    contentTop: contentTop,
                                    items: rects,
                                    height: sectionHeight))
            y += sectionHeight
        }

        self.sections = sections
        self.contentSize = NSSize(width: width, height: y)
        self.columns = columns
        self.itemWidth = itemWidth
    }

    func sectionIndex(atY y: CGFloat) -> Int? {
        guard !sections.isEmpty else { return nil }
        var low = 0
        var high = sections.count - 1
        var result: Int?
        while low <= high {
            let middle = (low + high) / 2
            let top = sections[middle].header.minY
            if top <= y {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return result ?? 0
    }

    func item(at point: CGPoint) -> (section: Int, item: Int)? {
        guard let section = sectionIndex(atY: point.y) else { return nil }
        for (index, rect) in sections[section].items.enumerated() where rect.contains(point) {
            return (section, index)
        }
        return nil
    }
}

private final class GridTileLayer: CALayer {
    private let badge = CATextLayer()

    override init() {
        super.init()
        contentsGravity = .resizeAspectFill
        masksToBounds = true
        cornerRadius = 6
        backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.14).cgColor

        badge.string = "▶"
        badge.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        badge.fontSize = 12
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.alignmentMode = .center
        badge.cornerRadius = 10
        badge.isHidden = true
        addSublayer(badge)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(image: CGImage?, isVideo: Bool) {
        contents = image
        badge.isHidden = !isVideo
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = CGRect(x: max(bounds.width - 26, 0), y: 6, width: 20, height: 20)
        CATransaction.commit()
    }
}

/// The scrolling document. It contains only the visible tile layers; the
/// pinned header lives above the scroll view in `GridContainerView`.
final class GridCanvasView: NSView {
    private(set) var layout = GridCanvasLayout(groups: [], width: 900, minimumItemWidth: 160)
    private var groups: [MediaGroup] = []
    private var rootURL: URL?
    private var tier: ThumbnailTier = .grid
    private var tiles: [String: GridTileLayer] = [:]
    private var tilePool: [GridTileLayer] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastVisibleKeys: Set<String> = []

    var onOpen: ((MediaItem) -> Void)?
    var onPrefetch: ((MediaItem, ThumbnailTier) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(groups: [MediaGroup],
                   rootURL: URL,
                   tier: ThumbnailTier,
                   width: CGFloat,
                   minimumItemWidth: CGFloat) {
        clearTiles()
        self.groups = groups
        self.rootURL = rootURL
        self.tier = tier
        rebuildLayout(width: width, minimumItemWidth: minimumItemWidth)
    }

    private func clearTiles() {
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        for (_, tile) in tiles { tile.removeFromSuperlayer() }
        for tile in tilePool { tile.removeFromSuperlayer() }
        tiles.removeAll()
        tilePool.removeAll()
        lastVisibleKeys.removeAll()
    }

    func rebuildLayout(width: CGFloat, minimumItemWidth: CGFloat) {
        layout = GridCanvasLayout(groups: groups, width: width, minimumItemWidth: minimumItemWidth)
        var frame = self.frame
        frame.size = layout.contentSize
        self.frame = frame
        updateVisible(force: true)
    }

    func updateVisible(force: Bool = false) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView.bounds
        let margin = layout.itemWidth * 0.5
        let visible = NSRect(x: 0,
                             y: max(clip.minY - margin, 0),
                             width: bounds.width,
                             height: clip.height + margin * 2)
        let sectionRange = layout.sections.indices.filter {
            let section = layout.sections[$0]
            return CGRect(x: 0, y: section.header.minY, width: layout.contentSize.width, height: section.height)
                .intersects(visible)
        }
        var keys: Set<String> = []
        var entries: [(String, Int, Int, CGRect)] = []

        let rowHeight = layout.itemWidth + GridCanvasLayout.lineSpacing
        for section in sectionRange {
            let descriptor = layout.sections[section]
            guard !descriptor.items.isEmpty else { continue }
            let firstRow = max(0, Int(floor((visible.minY - descriptor.contentTop) / rowHeight)) - 1)
            let lastRow = max(firstRow, Int(ceil((visible.maxY - descriptor.contentTop) / rowHeight)))
            let lower = min(descriptor.items.count, max(0, firstRow * layout.columns))
            let upper = min(descriptor.items.count, max(lower, (lastRow + 1) * layout.columns))
            guard lower < upper else { continue }
            for item in lower..<upper {
                let rect = descriptor.items[item]
                guard rect.intersects(visible) else { continue }
                let key = "\(section):\(item)"
                keys.insert(key)
                entries.append((key, section, item, rect))
            }
        }

        guard force || keys != lastVisibleKeys else { return }
        let newKeys = keys.subtracting(lastVisibleKeys)
        lastVisibleKeys = keys

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, tile) in tiles where !keys.contains(key) {
            tile.isHidden = true
            tile.configure(image: nil, isVideo: false)
            tilePool.append(tile)
            tiles.removeValue(forKey: key)
            tasks.removeValue(forKey: key)?.cancel()
        }

        for (key, section, item, rect) in entries {
            let descriptor = layout.sections[section]
            guard groups.indices.contains(descriptor.groupIndex),
                  groups[descriptor.groupIndex].items.indices.contains(item) else { continue }
            let media = groups[descriptor.groupIndex].items[item]

            let tile: GridTileLayer
            if let existing = tiles[key] {
                existing.frame = rect
                continue
            } else if let recycled = tilePool.popLast() {
                tile = recycled
                tile.isHidden = false
                tiles[key] = tile
            } else {
                tile = GridTileLayer()
                layer?.addSublayer(tile)
                tiles[key] = tile
            }
            tile.frame = rect

            let input = ThumbnailInput(relativePath: media.relativePath,
                                       modificationDate: media.contentModificationDate,
                                       mediaType: media.mediaType)
            guard let rootURL else { continue }
            if let cached = ThumbnailGenerator.shared.cachedImage(for: input, tier: tier, rootURL: rootURL) {
                tile.configure(image: cached, isVideo: media.isVideo)
            } else {
                tile.configure(image: nil, isVideo: media.isVideo)
                loadImage(for: key, input: input, media: media, tile: tile)
            }
            if newKeys.contains(key) {
                onPrefetch?(media, tier)
            }
        }
        CATransaction.commit()
    }

    private func loadImage(for key: String,
                           input: ThumbnailInput,
                           media: MediaItem,
                           tile: GridTileLayer) {
        guard tasks[key] == nil, let rootURL else { return }
        let requestedTier = tier
        tasks[key] = Task { @MainActor [weak self] in
            let image = await rootURL.withSecurityScope {
                await ThumbnailGenerator.shared.thumbnail(for: input,
                                                         tier: requestedTier,
                                                         rootURL: rootURL,
                                                         priority: .utility)
            }
            guard let self else { return }
            defer { self.tasks.removeValue(forKey: key) }
            guard self.lastVisibleKeys.contains(key), let image else { return }
            tile.configure(image: image.cgImage, isVideo: media.isVideo)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = layout.item(at: point),
              layout.sections.indices.contains(hit.section) else { return }
        let descriptor = layout.sections[hit.section]
        guard groups.indices.contains(descriptor.groupIndex),
              groups[descriptor.groupIndex].items.indices.contains(hit.item) else { return }
        onOpen?(groups[descriptor.groupIndex].items[hit.item])
    }
}

private final class GridPinnedHeaderView: NSView {
    let chevron = NSImageView()
    let title = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        addSubview(chevron)
        addSubview(title)
        addSubview(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(group: MediaGroup, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        title.stringValue = group.title
        count.stringValue = group.isCollapsed ? "\(group.count)" : ""
        chevron.image = NSImage(systemSymbolName: group.isCollapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: nil)
    }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 8, y: 8, width: 14, height: 14)
        title.frame = NSRect(x: 28, y: 5, width: max(bounds.width - 52, 10), height: 20)
        count.frame = NSRect(x: max(bounds.width - 36, 0), y: 8, width: 30, height: 14)
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }
}

/// Owns the scroll view, the layer-backed document and the pinned section
/// header. Bounds notifications do only visible-tile bookkeeping.
final class GridContainerView: NSView {
    let scrollView = NSScrollView()
    let canvas = GridCanvasView()
    private let headerView = GridPinnedHeaderView()

    var onOpen: ((MediaItem) -> Void)? {
        didSet { canvas.onOpen = onOpen }
    }
    var onPrefetch: ((MediaItem, ThumbnailTier) -> Void)? {
        didSet { canvas.onPrefetch = onPrefetch }
    }
    var onToggle: ((MediaGroup) -> Void)?
    var onVisibleSection: ((String?) -> Void)?
    var onFastScrolling: ((Bool) -> Void)?
    var onLoadMore: (() -> Void)?

    private var loadMoreArmed = true
    private var groups: [MediaGroup] = []
    private var minimumItemWidth: CGFloat = 160
    private var lastTier: ThumbnailTier?
    private var lastRootPath: String?
    private var currentSection: Int?
    private var headerSignature = ""
    private var signature = ""
    private var lastLayoutWidth: CGFloat = -1
    private var boundsObserver: NSObjectProtocol?
    private var quietTimer: Timer?
    private var lastY: CGFloat = 0
    private var lastChangeTime: CFTimeInterval = 0
    private var isFast = false
    private var lastScrollToken: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = canvas
        addSubview(scrollView)

        headerView.isHidden = true
        addSubview(headerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(groups: [MediaGroup],
               rootURL: URL,
               tier: ThumbnailTier,
               minimumItemWidth: CGFloat,
               scrollTarget: TimeScrollTarget?,
               force: Bool) {
        let newSignature = Self.signature(for: groups)
        let geometryChanged = force || newSignature != signature
            || abs(self.minimumItemWidth - minimumItemWidth) > 0.5
            || lastTier != tier
            || lastRootPath != rootURL.path
        self.groups = groups
        self.minimumItemWidth = minimumItemWidth
        self.lastTier = tier
        self.lastRootPath = rootURL.path
        if geometryChanged {
            let anchor = force ? nil : topVisibleAnchor()
            signature = newSignature
            canvas.configure(groups: groups,
                             rootURL: rootURL,
                             tier: tier,
                             width: max(scrollView.contentView.bounds.width, 1),
                             minimumItemWidth: minimumItemWidth)
            if force {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                restore(anchor: anchor)
            }
        }
        if let target = scrollTarget, target.token != lastScrollToken {
            lastScrollToken = target.token
            scroll(toSectionID: target.groupID)
        }
        updateHeader()
    }

    private static func signature(for groups: [MediaGroup]) -> String {
        var value = ""
        value.reserveCapacity(groups.count * 32)
        for group in groups {
            value += group.id
            value += ":\(group.title):\(group.items.count):\(group.isCollapsed):"
            value += group.items.first?.id ?? ""
            value += ":"
            value += group.items.last?.id ?? ""
            value += "|"
        }
        return value
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds

        let width = scrollView.contentView.bounds.width
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            canvas.rebuildLayout(width: width, minimumItemWidth: minimumItemWidth)
        }

        headerView.frame = NSRect(x: 0, y: bounds.height - GridCanvasLayout.headerHeight,
                                  width: bounds.width, height: GridCanvasLayout.headerHeight)
        headerView.isHidden = currentSection == nil
        canvas.updateVisible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            detach()
        } else {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
    }

    private func attach() {
        guard boundsObserver == nil else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        lastY = clip.bounds.origin.y
        lastChangeTime = CACurrentMediaTime()
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.boundsChanged()
        }
    }

    private func boundsChanged() {
        let clip = scrollView.contentView
        let y = clip.bounds.origin.y
        let now = CACurrentMediaTime()
        if abs(y - lastY) > 0.5 {
            let dt = max(now - lastChangeTime, 0.001)
            let velocity = abs(y - lastY) / dt
            if velocity >= 900 { setFast(true) }
        }
        lastY = y
        lastChangeTime = now
        scheduleQuietCheck()
        canvas.updateVisible()
        updateHeader()
        checkLoadMore()
    }

    private func checkLoadMore() {
        let clip = scrollView.contentView.bounds
        let height = canvas.layout.contentSize.height
        if clip.maxY > height - 800, loadMoreArmed {
            loadMoreArmed = false
            onLoadMore?()
        } else if clip.maxY < height - 1200 {
            loadMoreArmed = true
        }
    }

    private func updateHeader() {
        let y = scrollView.contentView.bounds.origin.y + 1
        guard let section = canvas.layout.sectionIndex(atY: y),
              canvas.layout.sections.indices.contains(section),
              groups.indices.contains(canvas.layout.sections[section].groupIndex) else {
            currentSection = nil
            headerView.isHidden = true
            onVisibleSection?(nil)
            return
        }
        let group = groups[canvas.layout.sections[section].groupIndex]
        let newHeaderSignature = "\(group.id)|\(group.isCollapsed)|\(group.count)"
        if currentSection != section || headerSignature != newHeaderSignature {
            currentSection = section
            headerSignature = newHeaderSignature
            headerView.configure(group: group) { [weak self] in
                self?.onToggle?(group)
            }
            onVisibleSection?(group.id)
        }
        headerView.isHidden = false
    }

    private func scheduleQuietCheck() {
        quietTimer?.invalidate()
        let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.setFast(false)
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    private func setFast(_ value: Bool) {
        guard value != isFast else { return }
        isFast = value
        onFastScrolling?(value)
        if !value {
            // A fast fling skips paging; once it settles at the bottom, page in
            // the next batch without requiring another scroll event.
            loadMoreArmed = true
            checkLoadMore()
        }
    }

    func topVisibleAnchor() -> GridScrollAnchor? {
        let y = scrollView.contentView.bounds.origin.y + 1
        guard let section = canvas.layout.sectionIndex(atY: y),
              canvas.layout.sections.indices.contains(section) else { return nil }
        let descriptor = canvas.layout.sections[section]
        return GridScrollAnchor(sectionID: descriptor.id,
                                fraction: (y - descriptor.header.minY) / max(descriptor.height, 1))
    }

    func restore(anchor: GridScrollAnchor?) {
        guard let anchor,
              let section = canvas.layout.sections.firstIndex(where: { $0.id == anchor.sectionID }) else { return }
        let descriptor = canvas.layout.sections[section]
        scroll(toY: descriptor.header.minY + anchor.fraction * descriptor.height)
    }

    func scroll(toSectionID id: String) {
        guard let section = canvas.layout.sections.firstIndex(where: { $0.id == id }) else { return }
        scroll(toY: canvas.layout.sections[section].header.minY)
    }

    private func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(canvas.layout.contentSize.height - clip.bounds.height, 0)
        let target = min(max(y, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    private func detach() {
        quietTimer?.invalidate()
        quietTimer = nil
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
    }

    deinit { detach() }
}

struct GridScrollAnchor {
    let sectionID: String
    let fraction: CGFloat
}
