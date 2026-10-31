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
                            .transition(.opacity)
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

            if viewModel.isScanning && viewModel.items.isEmpty {
                ProgressView(viewModel.scanProgress)
                    .progressViewStyle(.linear)
                    .padding()
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
                        spacing: 8
                    ) {
                        ForEach(viewModel.groupedItems) { group in
                            Section {
                                if !group.isCollapsed {
                                    ForEach(group.items) { item in
                                        MediaCellView(
                                            item: item,
                                            rootURL: rootURL
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            viewModel.selectedItem = item
                                        }
                                        .onAppear {
                                            viewModel.prefetchThumbnails(around: item)
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

                    if viewModel.canLoadMore {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .task(id: viewModel.items.count) {
                                await viewModel.loadMoreItems()
                            }
                    }
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        let baseWidth: CGFloat = 160
        let cellWidth = max(60, baseWidth / viewModel.effectiveZoomLevel)
        return [GridItem(.adaptive(minimum: cellWidth), spacing: 8)]
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
