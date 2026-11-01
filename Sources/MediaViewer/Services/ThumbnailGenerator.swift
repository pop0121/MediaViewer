import AppKit
import AVFoundation
import CryptoKit
import Foundation
import ImageIO

/// An already-decoded image handed across concurrency domains. The wrapped
/// `CGImage` is immutable; `NSImage` is only a cheap view wrapper.
struct ThumbnailImage: @unchecked Sendable {
    let cgImage: CGImage

    var image: NSImage {
        NSImage(cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height))
    }
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

    /// Grid images are the hot path for a 3,000-item library. The user-approved
    /// budget keeps the 320 px layer resident instead of re-decoding on every
    /// LazyVGrid/NSCollectionView cell reuse.
    private static let defaultGridCacheBytes = 1024 * 1024 * 1024
    private static let defaultLargeCacheBytes = 512 * 1024 * 1024
    private static let defaultFullscreenCacheBytes = 512 * 1024 * 1024

    private let gridCache: CGImageLRU
    private let gridLargeCache: CGImageLRU
    private let fullscreenCache: CGImageLRU
    private let stateLock = NSLock()
    private var inFlight: [String: Task<ThumbnailImage?, Never>] = [:]
    private var hashCache: [String: String] = [:]
    private var urlCache: [String: URL] = [:]
    /// Bound disk reads and image decoding. Unbounded cell loads starve the
    /// main thread (and the window server) even though each load is small.
    private let loadGate = AsyncSemaphore(limit: 3)

    init() {
        let env = ProcessInfo.processInfo.environment
        gridCache = CGImageLRU(capacityBytes: Self.cacheBytes(
            env["MEDIAVIEWER_GRID_CACHE_MB"].flatMap(Int.init),
            defaultMB: Self.defaultGridCacheBytes / 1024 / 1024
        ))
        gridLargeCache = CGImageLRU(capacityBytes: Self.cacheBytes(
            env["MEDIAVIEWER_GRID_LARGE_CACHE_MB"].flatMap(Int.init),
            defaultMB: Self.defaultLargeCacheBytes / 1024 / 1024
        ))
        fullscreenCache = CGImageLRU(capacityBytes: Self.cacheBytes(
            env["MEDIAVIEWER_FULLSCREEN_CACHE_MB"].flatMap(Int.init),
            defaultMB: Self.defaultFullscreenCacheBytes / 1024 / 1024
        ))
    }

    private static func cacheBytes(_ mb: Int?, defaultMB: Int) -> Int {
        max(mb ?? defaultMB, 16) * 1024 * 1024
    }

    /// Return a cached thumbnail if available; otherwise generate and cache it.
    /// Concurrent requests for the same item share one decoding task.
    func thumbnail(
        for input: ThumbnailInput,
        tier: ThumbnailTier = .grid,
        rootURL: URL,
        priority: TaskPriority = .userInitiated
    ) async -> ThumbnailImage? {
        guard let thumbnailURL = thumbnailURL(for: input, tier: tier, rootURL: rootURL) else { return nil }

        let path = thumbnailURL.path
        if let cached = cache(for: tier).image(forKey: path) {
            return ThumbnailImage(cgImage: cached)
        }

        if let existing = inFlightTask(for: path) {
            return await existing.value
        }
        let task = Task.detached(priority: priority) { [self] in
            await loadGate.wait()
            let result = await loadOrGenerate(input: input, tier: tier, rootURL: rootURL, thumbnailURL: thumbnailURL)
            await loadGate.signal()
            return result
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
        let cacheKey = thumbnailURL.path
        if let cached = cache(for: tier).image(forKey: cacheKey) {
            return ThumbnailImage(cgImage: cached)
        }

        let sourceURL = rootURL.appendingPathComponent(input.relativePath)
        if FileManager.default.fileExists(atPath: thumbnailURL.path) {
            if let image = loadDecodedThumbnail(at: thumbnailURL, tier: tier),
               isThumbnailAdequate(image, tier: tier, sourceURL: sourceURL) {
                cache(for: tier).insert(image, forKey: cacheKey)
                return ThumbnailImage(cgImage: image)
            }
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        guard let image = await generateThumbnail(for: input, tier: tier, sourceURL: sourceURL) else {
            return nil
        }
        try? saveThumbnail(image, to: thumbnailURL, quality: tier.jpegQuality)
        cache(for: tier).insert(image, forKey: cacheKey)
        return ThumbnailImage(cgImage: image)
    }

    /// Synchronous memory-cache probe for a collection-view cell. This avoids
    /// spawning a Task for the common warm-cache case.
    func cachedImage(for input: ThumbnailInput,
                     tier: ThumbnailTier = .grid,
                     rootURL: URL) -> CGImage? {
        guard let url = thumbnailURL(for: input, tier: tier, rootURL: rootURL) else { return nil }
        return cache(for: tier).image(forKey: url.path)
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
        let key = url.path
        if let cached = cache(for: tier).image(forKey: key) {
            return NSImage(cgImage: cached, size: NSSize(width: cached.width, height: cached.height))
        }
        let sourceURL = rootURL.appendingPathComponent(input.relativePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = loadDecodedThumbnail(at: url, tier: tier),
              isThumbnailAdequate(image, tier: tier, sourceURL: sourceURL) else { return nil }
        cache(for: tier).insert(image, forKey: key)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // MARK: - Internal

    func thumbnailURL(for input: ThumbnailInput, tier: ThumbnailTier = .grid, rootURL: URL) -> URL? {
        let cacheKey = "\(rootURL.path)|\(input.relativePath)|\(input.modificationDate.timeIntervalSince1970)|\(tier.rawValue)"
        stateLock.lock()
        if let cached = urlCache[cacheKey] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        let thumbsDir = PersistenceController.thumbnailsDirectory(for: rootURL)
        let hash = stableHash("\(input.relativePath)|\(input.modificationDate.timeIntervalSince1970)")
        let url = thumbsDir.appendingPathComponent("\(hash)-\(tier.rawValue).jpg")

        stateLock.lock()
        urlCache[cacheKey] = url
        stateLock.unlock()
        return url
    }

    // MARK: - Private

    private func cache(for tier: ThumbnailTier) -> CGImageLRU {
        switch tier {
        case .grid: return gridCache
        case .gridLarge: return gridLargeCache
        case .fullscreen: return fullscreenCache
        }
    }

    /// Decode a cached JPEG off the caller's thread and return an already-decoded image.
    private func loadDecodedThumbnail(at url: URL, tier: ThumbnailTier) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [NSString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: tier.maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func generateThumbnail(for input: ThumbnailInput, tier: ThumbnailTier, sourceURL: URL) async -> CGImage? {
        if input.mediaType == .photo {
            return generatePhotoThumbnail(from: sourceURL, tier: tier)
        } else {
            return await generateVideoThumbnail(from: sourceURL, tier: tier)
        }
    }

    private func stableHash(_ input: String) -> String {
        stateLock.lock()
        if let cached = hashCache[input] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        let value = digest.compactMap { String(format: "%02x", $0) }.joined()

        stateLock.lock()
        hashCache[input] = value
        stateLock.unlock()
        return value
    }

    private func generatePhotoThumbnail(from url: URL, tier: ThumbnailTier) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let target = tier.maxPixelSize
        var options: [NSString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target
        ]

        // Only the grid tier tries an embedded EXIF preview. Even there it is
        // accepted only when its long edge reaches the physical target; a
        // 160px preview must not be used for a 320px grid layer. Larger tiers
        // decode the full image directly (their targets are far above typical
        // embedded previews).
        if tier == .grid {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let candidate = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
               max(candidate.width, candidate.height) >= target {
                return candidate
            }
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        }

        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A stored tier is reusable when it reaches the physical target, or when
    /// the source itself is smaller than the target (upscaling cannot add detail).
    private func isThumbnailAdequate(_ image: CGImage, tier: ThumbnailTier, sourceURL: URL) -> Bool {
        let longEdge = CGFloat(max(image.width, image.height))
        let target = CGFloat(tier.maxPixelSize)
        guard longEdge < target else { return true }
        // Video sources cannot be inspected with ImageIO. Keep their existing
        // poster rather than regenerating it on every access; their target is
        // bounded by decoded video dimensions, not by an embedded image preview.
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return true
        }
        let sourceLongEdge = CGFloat(max(width, height))
        return longEdge >= min(target, sourceLongEdge)
    }

    private func generateVideoThumbnail(from url: URL, tier: ThumbnailTier) async -> CGImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: tier.maxPixelSize, height: tier.maxPixelSize)

        do {
            let duration = try await asset.load(.duration)
            let time = CMTime(seconds: duration.seconds * 0.5, preferredTimescale: 600)
            let (cgImage, _) = try await generator.image(at: time)
            return cgImage
        } catch {
            Log.thumbnails.error("Failed to generate video thumbnail for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveThumbnail(_ image: CGImage, to url: URL, quality: CGFloat) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return }
        try data.write(to: url)
    }
}


private actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
