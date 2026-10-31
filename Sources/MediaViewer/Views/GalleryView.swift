import AppKit
import MapKit
import SwiftUI

struct GalleryView: View {
    @StateObject private var viewModel = LibraryViewModel()
    @State private var visibleRegion: MKCoordinateRegion?
    @AppStorage("gridDensity") private var storedDensity: Double = 1.0

    var body: some View {
        Group {
            if let rootURL = viewModel.rootURL {
                galleryContent(rootURL: rootURL)
                    .overlay {
                        if viewModel.selectedItem != nil {
                            FullscreenViewerView(
                                viewModel: viewModel,
                                rootURL: rootURL
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
            } else {
                RootSelectorView(rootURL: $viewModel.rootURL) { url in
                    viewModel.setRootURL(url)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onAppear {
            syncDensityFromStorage()
            viewModel.loadStoredRoot()
        }
    }

    @ViewBuilder
    private func galleryContent(rootURL: URL) -> some View {
        VStack(spacing: 0) {
            toolbar(rootURL: rootURL)

            if let clusterLabel = viewModel.clusterLabel {
                ClusterBreadcrumbView(label: clusterLabel) {
                    viewModel.backToMap()
                }
            } else if viewModel.groupingMode == .years
                        || viewModel.groupingMode == .months
                        || viewModel.groupingMode == .days {
                // Always reserve this row in time views: a breadcrumb that
                // appears mid-scroll would change the viewport height and jump.
                TimeBreadcrumbView(viewModel: viewModel)
            }

            if viewModel.isScanning {
                HStack(spacing: 8) {
                    if let fraction = viewModel.scanFraction {
                        ProgressView(value: fraction)
                            .frame(width: 160)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewModel.scanProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { viewModel.cancelScan() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            if viewModel.isScanning && viewModel.items.isEmpty {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Media Found")
                        .font(.title2)
                    Text("No supported photos or videos were found in the selected folder.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.groupingMode.isMap {
                mapContent(rootURL: rootURL)
            } else {
                gridContent(rootURL: rootURL)
            }

            if viewModel.groupingMode == .location {
                Text("Location names © OpenStreetMap contributors (ODbL)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func gridContent(rootURL: URL) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVGrid(
                columns: gridColumns,
                spacing: 8,
                pinnedViews: [.sectionHeaders]
            ) {
                ForEach(viewModel.groupedItems) { group in
                    Section {
                        if !group.isCollapsed {
                            ForEach(group.items) { item in
                                MediaCellView(
                                    item: item,
                                    rootURL: rootURL,
                                    isScrollingFast: viewModel.isFastScrolling,
                                    tier: thumbnailTier
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        viewModel.selectedItem = item
                                    }
                                }
                                .onAppear {
                                    viewModel.prefetchThumbnails(around: item, tier: thumbnailTier)
                                }
                            }
                        }
                    } header: {
                        Button {
                            viewModel.toggleCollapsed(for: group)
                        } label: {
                            HStack {
                                Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(group.title)
                                    .font(.headline)
                                Spacer()
                                Text("\(group.count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .background(SectionFrameReader(id: group.id, coordinateSpace: "gridScroll"))
                        .id(group.id)
                    }
                }
            }
            .padding(8)
            .background(
                ScrollActivityObserver { fast in
                    viewModel.setFastScrolling(fast)
                }
            )
            .onPreferenceChange(SectionFramePreferenceKey.self) { frames in
                viewModel.updateTopSection(TimeFocusResolver.topSection(frames: frames))
            }

            if viewModel.canLoadMore {
                ProgressView()
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .task(id: "\(viewModel.items.count)-\(viewModel.isFastScrolling)") {
                        await viewModel.loadMoreItems()
                    }
            }
        }
        .coordinateSpace(name: "gridScroll")
        .onChange(of: viewModel.scrollTarget) { target in
            guard let target else { return }
            DispatchQueue.main.async {
                proxy.scrollTo(target.groupID, anchor: .top)
            }
        }
        }
    }

    @ViewBuilder
    private func mapContent(rootURL: URL) -> some View {
        ZStack(alignment: .topLeading) {
            PlacesMapView(
                items: viewModel.items,
                rootURL: rootURL,
                initialRegion: viewModel.lastMapRegion,
                onOpen: { item in
                    withAnimation(.easeOut(duration: 0.18)) {
                        viewModel.selectedItem = item
                    }
                },
                onOpenCluster: { cluster in
                    viewModel.showClusterGrid(cluster: cluster)
                },
                onRegionChange: { region in
                    viewModel.lastMapRegion = region
                    visibleRegion = region
                }
            )

            VStack(alignment: .leading, spacing: 8) {
                if let region = visibleRegion, viewModel.clusterLabel == nil {
                    Button {
                        viewModel.showGrid(in: region)
                    } label: {
                        Label("Show Grid in This Area", systemImage: "square.grid.2x2")
                    }
                    .controlSize(.small)
                }
                if viewModel.itemsWithoutLocationCount > 0 {
                    Text("\(viewModel.itemsWithoutLocationCount) without location")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
            }
            .padding(12)

            if viewModel.items.allSatisfy({ $0.coordinate == nil }) {
                Text("No photos with location information")
                    .font(.headline)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
        }
        .task(id: viewModel.isScanning) {
            if !viewModel.isScanning {
                await viewModel.loadAllItems()
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: gridCellWidth), spacing: 8)]
    }

    private var gridCellWidth: CGFloat {
        max(60, 160 * viewModel.effectiveDensity)
    }

    private var thumbnailTier: ThumbnailTier {
        ThumbnailTier.tier(forCellWidth: gridCellWidth,
                           backingScale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    private var densityBinding: Binding<Double> {
        Binding(
            get: { storedDensity },
            set: { value in
                setDensity(value)
            }
        )
    }

    private func setDensity(_ value: Double) {
        let clamped = LibraryViewModel.clampDensity(value)
        storedDensity = clamped
        viewModel.setDensity(clamped)
    }

    /// Move a legacy `zoomLevel` default (0.3...2.0) into `gridDensity`,
    /// clamped to the new 0.5...2.0 contract.
    private func syncDensityFromStorage() {
        let defaults = UserDefaults.standard
        let migrated = DensityPreferences.storedValue(in: defaults) ?? 1.0
        storedDensity = migrated
        if abs(viewModel.gridDensity - storedDensity) > 0.001 {
            viewModel.setDensity(storedDensity)
        }
    }

    @ViewBuilder
    private func toolbar(rootURL: URL) -> some View {
        HStack(spacing: 16) {
            GroupingPickerView(mode: Binding(
                get: { viewModel.groupingMode },
                set: { viewModel.selectGranularity($0) }
            ))

            HStack(spacing: 4) {
                Text("Small")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    setDensity(viewModel.gridDensity - 0.1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("-", modifiers: .command)
                .help("Smaller thumbnails (⌘−)")

                Slider(value: densityBinding, in: LibraryViewModel.densityRange, step: 0.1)
                    .frame(width: 130)
                    .help("Thumbnail density")

                Button {
                    setDensity(viewModel.gridDensity + 0.1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("+", modifiers: .command)
                .help("Larger thumbnails (⌘+)")

                Text(String(format: "%.1f×", storedDensity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .leading)

                Menu {
                    ForEach(Array(LibraryViewModel.densityPresets.enumerated()), id: \.offset) { _, preset in
                        Button(String(format: "%.1f×", preset)) {
                            setDensity(preset)
                        }
                    }
                } label: {
                    Image(systemName: "square.grid.3x3")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
                .help("Density presets")

                Text("Large")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if viewModel.groupingMode.isMap {
                Text("\(viewModel.itemsWithoutLocationCount) without location")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.regionFilter != nil {
                Button {
                    viewModel.clearRegionFilter()
                } label: {
                    Label("Clear Map Area", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }

            Spacer()

            Text("\(viewModel.items.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: {
                Task { await viewModel.refresh() }
            }) {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isScanning)

            Button("Change Folder…") {
                viewModel.cancelWork()
                viewModel.rootURL = nil
                viewModel.selectedItem = nil
                viewModel.items = []
                viewModel.groupedItems = []
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: viewModel.groupingMode) { mode in
            if mode.isMap {
                viewModel.clearRegionFilter()
            }
        }
    }
}
