import AppKit
import SwiftUI

struct MediaCellView: View {
    let item: MediaItem
    let rootURL: URL
    let isScrollingFast: Bool
    let tier: ThumbnailTier

    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    var body: some View {
        if isScrollingFast {
            // Cheap path while flinging: no geometry reader, image drawing,
            // icons or tasks. Thumbnails return when scrolling settles.
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .aspectRatio(1, contentMode: .fit)
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))
                            .overlay {
                                if isLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: item.isVideo ? "film" : "photo")
                                        .foregroundStyle(.secondary)
                                }
                            }
                    }

                    if item.isVideo {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .padding(6)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .aspectRatio(1, contentMode: .fit)
            .task(id: taskID) {
                await loadThumbnail()
            }
        }
    }

    private var taskID: String {
        "\(item.id)|\(item.contentModificationDate.timeIntervalSince1970)|\(tier.rawValue)"
    }

    private func loadThumbnail() async {
        if thumbnail == nil {
            isLoading = true
        }
        let input = ThumbnailInput(
            relativePath: item.relativePath,
            modificationDate: item.contentModificationDate,
            mediaType: item.mediaType
        )

        let image = await rootURL.withSecurityScope {
            await ThumbnailGenerator.shared.thumbnail(for: input, tier: tier, rootURL: rootURL)
        }

        guard !Task.isCancelled, !isScrollingFast else { return }
        self.thumbnail = image?.image
        self.isLoading = false
    }
}
