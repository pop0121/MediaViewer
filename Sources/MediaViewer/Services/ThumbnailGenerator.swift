import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// An already-decoded image handed across concurrency domains. The wrapped
/// `NSImage` is created from an immutable `CGImage` and is never mutated.
struct ThumbnailImage: @unchecked Sendable {
    let image: NSImage
}

struct ThumbnailInput: Sendable {
    let relativePath: String
    let modificationDate: Date
    let mediaType: MediaItem.MediaType
}

enum ThumbnailTier: String, Sendable, CaseIterable {
    /// Default grid cells (up to 160 pt at 2× Retina).
    case grid
    /// Larger zoomed-out cells; requested when cell pixels exceed 320.
    case gridLarge = "grid-640"
    /// Placeholder for the full-screen viewer, replaced by the original image.
    case fullscreen

    var maxPixelSize: Int {
        switch self {
        case .grid: return 320
        case .gridLarge: return 640
        case .fullscreen: return 1024
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .grid: return 0.8
        case .gridLarge: return 0.82
        case .fullscreen: return 0.85
        }
    }

    /// Pick the smallest tier that still covers `cellWidth × backingScale`.
    static func tier(forCellWidth width: CGFloat, backingScale: CGFloat) -> ThumbnailTier {
        let pixels = width * backingScale
        if pixels <= 320 { return .grid }
        if pixels <= 640 { return .gridLarge }
        return .fullscreen
    }
}

final class ThumbnailGenerator: @unchecked Sendable {
    static let shared = ThumbnailGenerator()

    private let gridCache = NSCache<NSString, NSImage>()
    private let gridLargeCache = NSCache<NSString, NSImage>()
    private let fullscreenCache = NSCache<NSString, NSImage>()
    private let stateLock = NSLock()
    private var inFlight: [String: Task<ThumbnailImage?, Never>] = [:]

    init() {
        // 320 px bitmaps are ~0.3 MB decoded: 256 MB ≈ 850 images.
        gridCache.countLimit = 2_000
        gridCache.totalCostLimit = 256 * 1024 * 1024
        // 640 px bitmaps are ~1.1 MB decoded: 192 MB ≈ 176 images.
        gridLargeCache.countLimit = 512
        gridLargeCache.totalCostLimit = 192 * 1024 * 1024
        // 1024 px placeholders are ~3 MB decoded: 128 MB ≈ 42 images.
        fullscreenCache.countLimit = 64
        fullscreenCache.totalCostLimit = 128 * 1024 * 1024
    }

    /// Return a cached thumbnail if available; otherwise generate and cache it.
    /// Concurrent requests for the same item share one decoding task.
    func thumbnail(
        for input: ThumbnailInput,
        tier: ThumbnailTier = .grid,
        rootURL: URL
    ) async -> ThumbnailImage? {
        guard let thumbnailURL = thumbnailURL(for: input, tier: tier, rootURL: rootURL) else { return nil }

        let cacheKey = thumbnailURL.path as NSString
        if let cached = cache(for: tier).object(forKey: cacheKey) {
            return ThumbnailImage(image: cached)
        }

        let path = thumbnailURL.path
        if let existing = inFlightTask(for: path) {
            return await existing.value
        }
        let task = Task.detached(priority: .userInitiated) { [self] in
            await loadOrGenerate(input: input, tier: tier, rootURL: rootURL, thumbnailURL: thumbnailURL)
        }
        setInFlightTask(task, for: path)

        let result = await task.value
        clearInFlightTask(for: path)
        return result
    }

    private func inFlightTask(for path: String) -> Task<ThumbnailImage?, Never>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inFlight[path]
    }

    private func setInFlightTask(_ task: Task<ThumbnailImage?, Never>, for path: String) {
        stateLock.lock()
        inFlight[path] = task
        stateLock.unlock()
    }

    private func clearInFlightTask(for path: String) {
        stateLock.lock()
        inFlight.removeValue(forKey: path)
        stateLock.unlock()
    }

    private func loadOrGenerate(
        input: ThumbnailInput,
        tier: ThumbnailTier,
        rootURL: URL,
        thumbnailURL: URL
    ) async -> ThumbnailImage? {
        let cacheKey = thumbnailURL.path as NSString
        if let cached = cache(for: tier).object(forKey: cacheKey) {
            return ThumbnailImage(image: cached)
        }

        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            if let image = loadDecodedThumbnail(at: thumbnailURL, tier: tier) {
                cache(for: tier).setObject(image, forKey: cacheKey, cost: image.cost)
                return ThumbnailImage(image: image)
            }
        }

        let sourceURL = rootURL.appendingPathComponent(input.relativePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let image = await generateThumbnail(for: input, tier: tier, sourceURL: sourceURL)
        if let image {
            try? saveThumbnail(image, to: thumbnailURL, quality: tier.jpegQuality)
            cache(for: tier).setObject(image, forKey: cacheKey, cost: image.cost)
        }
        return image.map(ThumbnailImage.init(image:))
    }

    /// Remove every tier for a deleted/changed item.
    func removeThumbnails(for input: ThumbnailInput, rootURL: URL) {
        for tier in ThumbnailTier.allCases {
            guard let url = thumbnailURL(for: input, tier: tier, rootURL: rootURL) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Remove orphaned thumbnails that no longer correspond to an indexed item.
    func purgeOrphanedThumbnails(rootURL: URL, validInputs: [ThumbnailInput]) async {
        var validPaths = Set<String>()
        validPaths.reserveCapacity(validInputs.count * 2)
        for input in validInputs {
            for tier in ThumbnailTier.allCases {
                if let url = thumbnailURL(for: input, tier: tier, rootURL: rootURL) {
                    validPaths.insert(url.path)
                }
            }
        }

        let thumbsDir = PersistenceController.thumbnailsDirectory(for: rootURL)
        guard let files = try? FileManager.default.contentsOfDirectory(at: thumbsDir,
                                                                        includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where !validPaths.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Read an already generated tier without touching the original image.
    /// Map cards use this first so opening a map never decodes full photos.
    func cachedThumbnail(
        for input: ThumbnailInput,
        tier: ThumbnailTier = .grid,
        rootURL: URL
    ) -> NSImage? {
        guard let url = thumbnailURL(for: input, tier: tier, rootURL: rootURL) else { return nil }
        let key = url.path as NSString
        if let cached = cache(for: tier).object(forKey: key) {
            return cached
        }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = loadDecodedThumbnail(at: url, tier: tier) else { return nil }
        cache(for: tier).setObject(image, forKey: key, cost: image.cost)
        return image
    }

    // MARK: - Internal

    func thumbnailURL(for input: ThumbnailInput, tier: ThumbnailTier = .grid, rootURL: URL) -> URL? {
        let thumbsDir = PersistenceController.thumbnailsDirectory(for: rootURL)
        let hash = stableHash("\(input.relativePath)|\(input.modificationDate.timeIntervalSince1970)")
        return thumbsDir.appendingPathComponent("\(hash)-\(tier.rawValue).jpg")
    }

    // MARK: - Private

    private func cache(for tier: ThumbnailTier) -> NSCache<NSString, NSImage> {
        switch tier {
        case .grid: return gridCache
        case .gridLarge: return gridLargeCache
        case .fullscreen: return fullscreenCache
        }
    }

    /// Decode a cached JPEG off the caller's thread and return an already-decoded image.
    private func loadDecodedThumbnail(at url: URL, tier: ThumbnailTier) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: tier.maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func generateThumbnail(for input: ThumbnailInput, tier: ThumbnailTier, sourceURL: URL) async -> NSImage? {
        if input.mediaType == .photo {
            return generatePhotoThumbnail(from: sourceURL, tier: tier)
        } else {
            return await generateVideoThumbnail(from: sourceURL, tier: tier)
        }
    }

    private func stableHash(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func generatePhotoThumbnail(from url: URL, tier: ThumbnailTier) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // Grid thumbnails use the embedded EXIF thumbnail when present (fast);
        // full-screen placeholders always downsample the full image.
        var options: [NSString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: tier.maxPixelSize
        ]
        if tier == .grid {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func generateVideoThumbnail(from url: URL, tier: ThumbnailTier) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: tier.maxPixelSize, height: tier.maxPixelSize)

        do {
            let duration = try await asset.load(.duration)
            let time = CMTime(seconds: duration.seconds * 0.5, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: time)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            Log.thumbnails.error("Failed to generate video thumbnail for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveThumbnail(_ image: NSImage, to url: URL, quality: CGFloat) throws {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = image.size
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return }
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
