import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO

struct ThumbnailInput {
    let relativePath: String
    let modificationDate: Date
    let mediaType: MediaItem.MediaType
}

final class ThumbnailGenerator {
    static let shared = ThumbnailGenerator()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let thumbnailSize: CGFloat = 480

    init() {
        // Cap in-memory cache so huge libraries don't exhaust RAM.
        memoryCache.countLimit = 200
        memoryCache.totalCostLimit = 200 * 1024 * 1024 // 200 MB
    }

    /// Return a cached thumbnail if available; otherwise generate and cache it.
    func thumbnail(for item: MediaItemEntity, rootURL: URL) async -> NSImage? {
        let input = ThumbnailInput(
            relativePath: item.relativePath,
            modificationDate: item.contentModificationDate,
            mediaType: item.mediaType
        )
        return await thumbnail(for: input, rootURL: rootURL)
    }

    /// Return a cached thumbnail for a lightweight `MediaItem`.
    func thumbnail(for item: MediaItem, rootURL: URL) async -> NSImage? {
        let input = ThumbnailInput(
            relativePath: item.relativePath,
            modificationDate: item.contentModificationDate,
            mediaType: item.mediaType
        )
        return await thumbnail(for: input, rootURL: rootURL)
    }

    func thumbnail(for input: ThumbnailInput, rootURL: URL) async -> NSImage? {
        guard let thumbnailURL = thumbnailURL(for: input, rootURL: rootURL) else { return nil }

        let key = thumbnailURL.path as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached
        }

        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            if let image = NSImage(contentsOf: thumbnailURL) {
                memoryCache.setObject(image, forKey: key, cost: image.cost)
                return image
            }
        }

        let sourceURL = rootURL.appendingPathComponent(input.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let image = await generateThumbnail(for: input, sourceURL: sourceURL)
        if let image {
            try? saveThumbnail(image, to: thumbnailURL)
            memoryCache.setObject(image, forKey: key, cost: image.cost)
        }
        return image
    }

    /// Generate thumbnails for many items concurrently, bounded by `maxConcurrent`.
    func generateThumbnails(
        for inputs: [ThumbnailInput],
        rootURL: URL,
        maxConcurrent: Int = 8
    ) async {
        guard !inputs.isEmpty else { return }

        let chunks = inputs.chunked(into: maxConcurrent)
        for chunk in chunks {
            await withTaskGroup(of: Void.self) { group in
                for input in chunk {
                    group.addTask {
                        _ = await self.thumbnail(for: input, rootURL: rootURL)
                    }
                }
                await group.waitForAll()
            }
        }
    }

    /// Clear any existing thumbnail for an item so it will be regenerated.
    func invalidateThumbnail(for input: ThumbnailInput, rootURL: URL) {
        guard let url = thumbnailURL(for: input, rootURL: rootURL) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove orphaned thumbnails that no longer correspond to an indexed item.
    func purgeOrphanedThumbnails(rootURL: URL, validInputs: [ThumbnailInput]) async {
        let validPaths = Set(validInputs.compactMap { thumbnailURL(for: $0, rootURL: rootURL)?.path })
        let thumbsDir = PersistenceController.thumbnailsDirectory(for: rootURL)
        guard let files = try? FileManager.default.contentsOfDirectory(at: thumbsDir,
                                                                        includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            if !validPaths.contains(file.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Internal

    func thumbnailURL(for input: ThumbnailInput, rootURL: URL) -> URL? {
        let thumbsDir = PersistenceController.thumbnailsDirectory(for: rootURL)
        let hash = stableHash("\(input.relativePath)|\(input.modificationDate.timeIntervalSince1970)")
        return thumbsDir.appendingPathComponent("\(hash).jpg")
    }

    // MARK: - Private

    private func generateThumbnail(for input: ThumbnailInput, sourceURL: URL) async -> NSImage? {
        if input.mediaType == .photo {
            return await generatePhotoThumbnail(from: sourceURL)
        } else {
            return await generateVideoThumbnail(from: sourceURL)
        }
    }

    private func stableHash(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func generatePhotoThumbnail(from url: URL) async -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(thumbnailSize, thumbnailSize) * 2
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func generateVideoThumbnail(from url: URL) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailSize * 2, height: thumbnailSize * 2)

        do {
            let duration = try await asset.load(.duration)
            let time = CMTime(seconds: duration.seconds * 0.5, preferredTimescale: 600)
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            print("Failed to generate video thumbnail for \(url): \(error.localizedDescription)")
            return nil
        }
    }

    private func saveThumbnail(_ image: NSImage, to url: URL) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try data.write(to: url)
    }
}

private extension NSImage {
    /// Rough cost in bytes for NSCache accounting based on actual bitmap pixels.
    var cost: Int {
        let pixels = representations.reduce(0) { total, rep in
            total + rep.pixelsWide * rep.pixelsHigh
        }
        let bytesPerPixel = 4
        return max(pixels * bytesPerPixel, 1)
    }
}
