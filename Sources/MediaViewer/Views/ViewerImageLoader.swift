import AppKit
import Foundation
import ImageIO

/// Progressive full-screen image loading: a cached 1024 px thumbnail first,
/// then a screen-sized decode, then the native resolution on demand (zoom).
@MainActor
final class ViewerImageLoader: ObservableObject {
    /// Long edge used for the first interactive decode. A 2000 px image costs
    /// ~10.7 MB decoded, well below the native 84 MB for a 22 MP photo.
    nonisolated static let screenMaxPixel = 2000

    @Published private(set) var placeholder: NSImage?
    @Published private(set) var screenImage: NSImage?
    @Published private(set) var highResImage: NSImage?
    @Published private(set) var isLoadingHighRes = false

    private var currentItemID: String?
    private var highResTask: Task<Void, Never>?

    func load(item: MediaItem, rootURL: URL) async {
        currentItemID = item.id
        highResTask?.cancel()
        highResTask = nil
        placeholder = nil
        screenImage = nil
        highResImage = nil
        isLoadingHighRes = false

        guard item.isPhoto else { return }

        let input = ThumbnailInput(
            relativePath: item.relativePath,
            modificationDate: item.contentModificationDate,
            mediaType: item.mediaType
        )
        let cached = await rootURL.withSecurityScope {
            await ThumbnailGenerator.shared.thumbnail(for: input, tier: .fullscreen, rootURL: rootURL)
        }
        guard currentItemID == item.id, !Task.isCancelled else { return }
        placeholder = cached?.image

        let url = rootURL.appendingPathComponent(item.relativePath)
        let root = rootURL
        let screen = await Task.detached(priority: .userInitiated) {
            root.withSecurityScope {
                Self.decodeImage(at: url, maxPixel: Self.screenMaxPixel)
            }
        }.value
        guard currentItemID == item.id, !Task.isCancelled else { return }
        screenImage = screen?.image
    }

    /// Decode the native resolution in the background. Called when the user
    /// zooms past the screen-sized image; a no-op while one is in flight.
    func loadHighResolution(item: MediaItem, rootURL: URL) {
        guard item.isPhoto, highResImage == nil, !isLoadingHighRes else { return }
        let id = item.id
        isLoadingHighRes = true
        let url = rootURL.appendingPathComponent(item.relativePath)
        let root = rootURL

        highResTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                root.withSecurityScope {
                    Self.decodeImage(at: url, maxPixel: nil)
                }
            }.value
            guard let self, !Task.isCancelled, self.currentItemID == id else { return }
            self.highResImage = image?.image
            self.isLoadingHighRes = false
        }
    }

    func reset() {
        currentItemID = nil
        highResTask?.cancel()
        highResTask = nil
        placeholder = nil
        screenImage = nil
        highResImage = nil
        isLoadingHighRes = false
    }

    /// Decode off the caller's thread with EXIF orientation applied and the
    /// bitmap cached immediately. `maxPixel == nil` means native resolution.
    nonisolated static func decodeImage(at url: URL, maxPixel: Int?) -> ThumbnailImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixel {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return ThumbnailImage(image: image)
    }
}
