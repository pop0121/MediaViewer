import AppKit
import SwiftUI

struct FullscreenViewerView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let rootURL: URL

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var videoIsPlaying = true
    @State private var eventMonitor: Any?
    @StateObject private var imageLoader = ViewerImageLoader()

    private var currentIndex: Int? {
        guard let selected = viewModel.selectedItem else { return nil }
        return viewModel.items.firstIndex { $0.id == selected.id }
    }

    private var currentItem: MediaItem? {
        viewModel.selectedItem
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let item = currentItem {
                content(for: item)
                    .id(item.id)
                    .scaleEffect(item.isPhoto ? scale : 1.0)
                    .offset(item.isPhoto ? offset : .zero)
                    .gesture(item.isPhoto ? magnificationGesture : nil)
                    .gesture(item.isPhoto ? dragGesture : nil)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                Spacer()

                if let item = currentItem, let date = item.formattedDate {
                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 16)
                }
            }

            navigationOverlay
        }
        .ignoresSafeArea()
        .onAppear {
            installKeyMonitor()
            loadCurrentItem()
            prefetchNeighbors()
        }
        .onChange(of: currentItem?.id) { _ in
            resetZoom()
            videoIsPlaying = true
            loadCurrentItem()
            prefetchNeighbors()
        }
        .onDisappear {
            removeKeyMonitor()
            imageLoader.reset()
            videoIsPlaying = false
        }
    }

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        if item.isVideo {
            if let url = rootURL.appendingPathComponent(item.relativePath) as URL? {
                VideoPlayerView(url: url, isPlaying: $videoIsPlaying)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            if let image = imageLoader.highResImage ?? imageLoader.screenImage ?? imageLoader.placeholder {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .foregroundStyle(.white)
            }
        }
    }

    private var navigationOverlay: some View {
        HStack {
            Button(action: previousItem) {
                Image(systemName: "chevron.left")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: nextItem) {
                Image(systemName: "chevron.right")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                scale = max(1.0, scale * delta)
            }
            .onEnded { _ in
                lastScale = 1.0
                if scale < 1.0 {
                    withAnimation {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                } else if scale >= 1.4, let item = currentItem {
                    imageLoader.loadHighResolution(item: item, rootURL: rootURL)
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                lastOffset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
    }

    // MARK: - Actions

    private func previousItem() {
        guard let index = currentIndex, index > 0 else { return }
        resetZoom()
        viewModel.selectedItem = viewModel.items[index - 1]
    }

    private func nextItem() {
        guard let index = currentIndex, index < viewModel.items.count - 1 else { return }
        resetZoom()
        viewModel.selectedItem = viewModel.items[index + 1]
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) {
            viewModel.selectedItem = nil
        }
    }

    private func resetZoom() {
        scale = 1.0
        lastScale = 1.0
        offset = .zero
        lastOffset = .zero
    }

    private func togglePlayPause() {
        guard currentItem?.isVideo == true else { return }
        videoIsPlaying.toggle()
    }

    // MARK: - Keyboard Monitor

    private func installKeyMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
        }
    }

    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Leave system shortcuts (Cmd, Option, Ctrl) untouched so Hide, Minimize,
        // Spotlight, Mission Control, and window-manager shortcuts keep working.
        let consumedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        let hasConsumedModifier = !event.modifierFlags.intersection(consumedModifiers).isEmpty

        switch event.keyCode {
        case 53: // Escape
            close()
            return nil
        case 49 where !hasConsumedModifier: // Space
            togglePlayPause()
            return nil
        case 123 where !hasConsumedModifier, 126 where !hasConsumedModifier: // Left arrow, Up arrow
            previousItem()
            return nil
        case 124 where !hasConsumedModifier, 125 where !hasConsumedModifier: // Right arrow, Down arrow
            nextItem()
            return nil
        default:
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Helpers

    private func loadCurrentItem() {
        guard let item = currentItem else {
            imageLoader.reset()
            return
        }
        Task { await imageLoader.load(item: item, rootURL: rootURL) }
    }

    /// Warm the 1024 px placeholders for the previous/next items.
    private func prefetchNeighbors() {
        guard let index = currentIndex, !viewModel.items.isEmpty else { return }
        let lower = max(0, index - 2)
        let upper = min(viewModel.items.count, index + 3)
        let inputs = viewModel.items[lower..<upper].map {
            ThumbnailInput(
                relativePath: $0.relativePath,
                modificationDate: $0.contentModificationDate,
                mediaType: $0.mediaType
            )
        }
        let root = rootURL
        Task.detached(priority: .utility) {
            for input in inputs {
                if Task.isCancelled { return }
                _ = await root.withSecurityScope {
                    await ThumbnailGenerator.shared.thumbnail(for: input, tier: .fullscreen, rootURL: root)
                }
            }
        }
    }
}
