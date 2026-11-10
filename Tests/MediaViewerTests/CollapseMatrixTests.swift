import AppKit
import XCTest
@testable import MediaViewer

@MainActor
final class CollapseMatrixTests: XCTestCase {
    private let calendar = Calendar.current
    private let root = URL(fileURLWithPath: "/tmp/mvbench/lib3k_clone")

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "collapsedGroupIDsByMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "collapsedGroupIDsByMode")
        super.tearDown()
    }

    private func item(_ index: Int, year: Int, month: Int, day: Int) -> MediaItem {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: index % 24))!
        return MediaItem(id: "i\(index)", relativePath: "m/i\(index).jpg", fileName: "i\(index).jpg",
                         fileSize: 1, contentModificationDate: date, derivedDate: date, dateSource: .filename,
                         coordinate: nil, locationName: nil, mediaType: .photo, thumbnailPath: nil,
                         albumNames: [])
    }

    private func items() -> [MediaItem] {
        let a = (0..<24).map { item($0, year: 2022, month: 1 + $0 % 12, day: 1 + $0 % 28) }
        let b = (100..<112).map { item($0, year: 2021, month: 1 + $0 % 12, day: 1 + $0 % 28) }
        let c = (200..<206).map { item($0, year: 2020, month: 1 + $0 % 12, day: 1 + $0 % 28) }
        return a + b + c
    }

    private func groups(_ collapsed: Set<String> = []) -> [MediaGroup] {
        let items = self.items()
        return [
            MediaGroup(id: "2022", title: "2022", items: items.filter { $0.id.hasPrefix("i0") || $0.id.hasPrefix("i1") }, isCollapsed: collapsed.contains("2022")),
            MediaGroup(id: "2021", title: "2021", items: items.filter { $0.id.hasPrefix("i1") }, isCollapsed: collapsed.contains("2021")),
            MediaGroup(id: "2020", title: "2020", items: items.filter { $0.id.hasPrefix("i2") }, isCollapsed: collapsed.contains("2020")),
        ]
    }

    private func makeViewModel() -> LibraryViewModel {
        let vm = LibraryViewModel()
        vm.items = items()
        return vm
    }

    // Matrix 1: single header click; the title label must not swallow the click.
    func testPinnedHeaderTitleRoutesToggle() {
        let view = GridContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.layoutSubtreeIfNeeded()
        var toggled: [String] = []
        view.onToggle = { toggled.append($0.id) }
        view.apply(groups: groups(), rootURL: root, tier: .grid, minimumItemWidth: 160, scrollTarget: nil, force: true)
        view.layoutSubtreeIfNeeded()

        guard let header = view.subviews.first(where: { String(describing: type(of: $0)).contains("PinnedHeader") }) else {
            return XCTFail("pinned header exists")
        }
        XCTAssertFalse(header.isHidden)
        let titlePoint = NSPoint(x: 40, y: 10)
        let hit = view.hitTest(view.convert(titlePoint, from: header))
        XCTAssertTrue(hit === header, "header itself, not NSTextField, receives title click: \(String(describing: hit))")
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: titlePoint, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 1, clickCount: 1, pressure: 1)!
        header.mouseDown(with: event)
        XCTAssertEqual(toggled, ["2022"])
    }

    // Matrix 1 + 6: collapsed group content disappears, height recalculates, and an
    // expand restores the exact original content.
    func testCanvasHeightAndContentForCollapseExpand() {
        let expanded = GridCanvasLayout(groups: groups(), width: 900, minimumItemWidth: 160)
        let collapsed = GridCanvasLayout(groups: groups(["2021"]), width: 900, minimumItemWidth: 160)
        XCTAssertEqual(collapsed.sections[1].height, GridCanvasLayout.headerHeight)
        XCTAssertTrue(collapsed.sections[1].items.isEmpty)
        XCTAssertEqual(collapsed.contentSize.height,
                       expanded.contentSize.height - expanded.sections[1].height + GridCanvasLayout.headerHeight)

        let view = GridContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view.onToggle = { _ in }
        view.layoutSubtreeIfNeeded()
        view.apply(groups: groups(), rootURL: root, tier: .grid, minimumItemWidth: 160, scrollTarget: nil, force: true)
        view.layoutSubtreeIfNeeded()
        view.apply(groups: groups(["2022", "2020"]), rootURL: root, tier: .grid, minimumItemWidth: 160, scrollTarget: nil, force: false)
        XCTAssertEqual(view.canvas.layout.sections[0].height, GridCanvasLayout.headerHeight)
        XCTAssertEqual(view.canvas.layout.sections[2].height, GridCanvasLayout.headerHeight)
        XCTAssertGreaterThan(view.canvas.layout.sections[1].height, GridCanvasLayout.headerHeight)

        view.apply(groups: groups(), rootURL: root, tier: .grid, minimumItemWidth: 160, scrollTarget: nil, force: false)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.canvas.layout.sections[0].items.count, groups()[0].items.count)
        XCTAssertEqual(view.canvas.layout.sections[0].height, expanded.sections[0].height)
    }

    // Matrix 2: collapsing a group above the viewport keeps the visible section
    // anchored instead of jumping.
    func testScrollAnchorPreservedWhenCollapsingAboveViewport() {
        let view = GridContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.onToggle = { _ in }
        view.layoutSubtreeIfNeeded()
        view.apply(groups: groups(), rootURL: root, tier: .grid, minimumItemWidth: 160, scrollTarget: nil, force: true)
        view.layoutSubtreeIfNeeded()

        let section1Y = view.canvas.layout.sections[1].header.minY + 10
        view.scroll(toYForTesting: section1Y)
        let before = view.scrollView.contentView.bounds.origin.y
        let visible = view.canvas.layout.sectionIndex(atY: before + 1)
        XCTAssertEqual(visible, 1)

        view.apply(groups: groups(["2022"]), rootURL: root, tier: .grid, minimumItemWidth: 160, scrollTarget: nil, force: false)
        let after = view.scrollView.contentView.bounds.origin.y
        let visibleAfter = view.canvas.layout.sectionIndex(atY: after + 1)
        XCTAssertEqual(visibleAfter, 1, "same section stays at the top after collapse above it")
        XCTAssertEqual(view.canvas.layout.sections[0].height, GridCanvasLayout.headerHeight)
        window.orderOut(nil)
        _ = before
    }

    // Matrix 3: collapsing in one mode survives a mode switch and back.
    func testCollapseStateSurvivesSegmentedModeSwitches() {
        let vm = makeViewModel()
        vm.selectGranularity(.years)
        let year = try! XCTUnwrap(vm.groupedItems.first { $0.id == "2022" })
        vm.toggleCollapsed(for: year)
        XCTAssertTrue(vm.groupedItems.first { $0.id == "2022" }?.isCollapsed == true)

        vm.selectGranularity(.months)
        XCTAssertTrue(vm.groupedItems.allSatisfy { !$0.isCollapsed })
        vm.selectGranularity(.years)
        XCTAssertTrue(vm.groupedItems.first { $0.id == "2022" }?.isCollapsed == true)
    }

    // Matrix 4: density changes do not regroup away collapse state.
    func testCollapseStateSurvivesDensityChange() {
        let vm = makeViewModel()
        vm.selectGranularity(.days)
        let day = try! XCTUnwrap(vm.groupedItems.first)
        vm.toggleCollapsed(for: day)
        let collapsedID = day.id
        vm.gridDensity = 0.5
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        vm.gridDensity = 1.5
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(vm.groupedItems.first { $0.id == collapsedID }?.isCollapsed == true)
    }

    // Matrix 5: Places round-trip preserves the time-mode collapse set.
    func testCollapseStateSurvivesPlacesRoundTrip() {
        let vm = makeViewModel()
        vm.selectGranularity(.years)
        let year = try! XCTUnwrap(vm.groupedItems.first { $0.id == "2022" })
        vm.toggleCollapsed(for: year)

        vm.backToMap()
        XCTAssertEqual(vm.groupingMode, .location)
        vm.selectGranularity(.years)
        XCTAssertTrue(vm.groupedItems.first { $0.id == "2022" }?.isCollapsed == true)
    }

    // Matrix 6 + 8: multiple groups (first and last), then all expand.
    func testMultipleGroupsAndExpandAll() {
        let vm = makeViewModel()
        vm.selectGranularity(.years)
        let first = try! XCTUnwrap(vm.groupedItems.first)
        let last = try! XCTUnwrap(vm.groupedItems.last)
        vm.toggleCollapsed(for: first)
        vm.toggleCollapsed(for: last)
        XCTAssertEqual(vm.groupedItems.filter(\.isCollapsed).map(\.id), [first.id, last.id])

        let layout = GridCanvasLayout(groups: vm.groupedItems, width: 900, minimumItemWidth: 160)
        XCTAssertEqual(layout.sections.first?.height, GridCanvasLayout.headerHeight)
        XCTAssertEqual(layout.sections.last?.height, GridCanvasLayout.headerHeight)
        XCTAssertGreaterThan(layout.contentSize.height, 0)

        // No "expand all" command exists in this app; expanding each header is
        // the explicit operation and must restore every section.
        for group in vm.groupedItems.filter(\.isCollapsed) {
            vm.toggleCollapsed(for: group)
        }
        XCTAssertTrue(vm.groupedItems.allSatisfy { !$0.isCollapsed })
    }

    // Matrix 7: drill-down landing stores a scroll target even when the target
    // group is collapsed; canvas resolves it to the target header.
    func testDrillLandingToCollapsedGroup() {
        let vm = makeViewModel()
        vm.selectGranularity(.years)
        vm.updateTopSection("2022")
        let year = try! XCTUnwrap(vm.groupedItems.first { $0.id == "2022" })
        vm.toggleCollapsed(for: year)
        vm.selectGranularity(.months)
        let target = try! XCTUnwrap(vm.scrollTarget?.groupID)
        XCTAssertTrue(target.hasPrefix("2022-"))
        let layout = GridCanvasLayout(groups: vm.groupedItems, width: 900, minimumItemWidth: 160)
        let section = layout.sections.first { $0.id == target }
        XCTAssertNotNil(section)
        XCTAssertEqual(section?.id, target)
    }

    // Matrix 9: rapid double click must be idempotent (toggle twice = original).
    func testRapidToggleIsStable() {
        let vm = makeViewModel()
        vm.selectGranularity(.years)
        let year = try! XCTUnwrap(vm.groupedItems.first)
        vm.toggleCollapsed(for: year)
        vm.toggleCollapsed(for: year)
        XCTAssertFalse(vm.groupedItems.first { $0.id == year.id }?.isCollapsed == true)
        vm.toggleCollapsed(for: year)
        XCTAssertTrue(vm.groupedItems.first { $0.id == year.id }?.isCollapsed == true)
    }

    // Inline headers are real canvas layers; hit testing must route to the
    // correct group, including groups below the pinned header.
    func testInlineHeaderLayerHitRoutesToggle() {
        let canvas = GridCanvasView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        var toggled: [String] = []
        canvas.onToggle = { toggled.append($0.id) }
        canvas.configure(groups: groups(), rootURL: root, tier: .grid, width: 900, minimumItemWidth: 160)
        canvas.layoutSubtreeIfNeeded()
        let header = canvas.layout.sections[1].header
        let point = NSPoint(x: header.midX, y: header.midY)
        XCTAssertEqual(canvas.layout.header(at: point), 1)
        let windowPoint = canvas.convert(point, to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 1, clickCount: 1, pressure: 1)!
        canvas.mouseDown(with: event)
        XCTAssertEqual(toggled, ["2021"])
        window.orderOut(nil)
    }
}

private extension GridContainerView {
    func scroll(toYForTesting y: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(canvas.layout.contentSize.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(y, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }
}
