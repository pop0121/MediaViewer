import AppKit
import SwiftUI

struct GalleryView: View {
    @StateObject private var viewModel = LibraryViewModel()

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
            viewModel.loadStoredRoot()
        }
    }

    @ViewBuilder
    private func galleryContent(rootURL: URL) -> some View {
        VStack(spacing: 0) {
            toolbar(rootURL: rootURL)

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
            } else {
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
                            }
                        }
                    }
                    .padding(8)
                    .background(
                        ScrollActivityObserver { fast in
                            viewModel.setFastScrolling(fast)
                        }
                    )

                    if viewModel.canLoadMore {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .task(id: "\(viewModel.items.count)-\(viewModel.isFastScrolling)") {
                                await viewModel.loadMoreItems()
                            }
                    }
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: gridCellWidth), spacing: 8)]
    }

    private var gridCellWidth: CGFloat {
        max(60, 160 / viewModel.effectiveZoomLevel)
    }

    private var thumbnailTier: ThumbnailTier {
        ThumbnailTier.tier(forCellWidth: gridCellWidth,
                           backingScale: NSScreen.main?.backingScaleFactor ?? 2)
    }

    @ViewBuilder
    private func toolbar(rootURL: URL) -> some View {
        HStack(spacing: 16) {
            GroupingPickerView(mode: $viewModel.groupingMode)

            HStack(spacing: 8) {
                Image(systemName: "minus")
                Slider(value: $viewModel.zoomLevel, in: 0.3...2.0, step: 0.1)
                    .frame(width: 150)
                Image(systemName: "plus")
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
    }
}
