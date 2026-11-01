import CoreData
import Foundation

final class MediaScanner {
    static let hiddenDirectoryName = ".mediaviewer"

    /// Maximum number of files whose metadata is extracted concurrently.
    /// This keeps memory reasonable while still saturating I/O for video metadata.
    private static let maxConcurrentExtractions = 8

    /// Metadata is applied/saved in batches of this size so the grid can publish
    /// indexed items before the whole scan finishes, without one save per file.
    private static let applyBatchSize = 256

    private let context: NSManagedObjectContext
    private let metadataExtractor = MetadataExtractor()

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Scan the root URL and update the Core Data index. Returns the number of new/changed items processed.
    func scan(
        rootURL: URL,
        progress: (@Sendable (ScanProgress) async -> Void)? = nil,
        indexed: (@Sendable ([MediaItem]) async -> Void)? = nil
    ) async throws -> ScanResult {
        try await self._scan(rootURL: rootURL, progress: progress, indexed: indexed)
    }

    private func _scan(
        rootURL: URL,
        progress: (@Sendable (ScanProgress) async -> Void)?,
        indexed: (@Sendable ([MediaItem]) async -> Void)?
    ) async throws -> ScanResult {
        let fileManager = FileManager.default
        let enumerateInterval = Perf.begin("scan.enumerate")

        // 1. Enumerate the filesystem and collect files that need (re)indexing.
        var discoveredRelativePaths = Set<String>()
        var changedFiles: [FileToIndex] = []

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                Log.scan.error("Enumerator error at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return true
            }
        ) else {
            throw ScanError.enumerationFailed
        }

        var enumeratedCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            enumeratedCount += 1
            if enumeratedCount % 256 == 0 {
                try Task.checkCancellation()
                await progress?(ScanProgress(phase: .enumerating, completed: enumeratedCount, total: 0))
            }
            let relativePath = fileURL.path(relativeTo: rootURL)

            // Skip our own cache directory and any explicitly-hidden system folders.
            if relativePath.hasPrefix("\(Self.hiddenDirectoryName)/") || relativePath == Self.hiddenDirectoryName {
                continue
            }
            if relativePath.hasPrefix(".database/") || relativePath == ".database" {
                continue
            }

            guard Self.isMediaFile(fileURL) else { continue }
            discoveredRelativePaths.insert(relativePath)

            let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modificationDate = resourceValues?.contentModificationDate ?? Date.distantPast
            let fileSize = Int64(resourceValues?.fileSize ?? 0)

            changedFiles.append(FileToIndex(
                url: fileURL,
                relativePath: relativePath,
                modificationDate: modificationDate,
                fileSize: fileSize
            ))
        }
        Perf.end(enumerateInterval, "enumerated=\(enumeratedCount) media=\(changedFiles.count)")
        try Task.checkCancellation()

        // 2. Load the existing index so we can skip unchanged files quickly.
        let existingItems = try await context.perform {
            try self.fetchAllItems()
        }
        var itemsByPath: [String: MediaItemEntity] = [:]
        itemsByPath.reserveCapacity(existingItems.count)
        for item in existingItems {
            itemsByPath[item.relativePath] = item
        }

        // Filter to only files whose modification date differs.
        let filesNeedingMetadata = changedFiles.filter { file in
            if let existing = itemsByPath[file.relativePath] {
                // The batch-13 date-source migration needs one metadata pass
                // over rows created before the source column existed. Rows
                // processed as genuinely unknown carry the "unknown" sentinel
                // and are not re-extracted on every launch.
                if existing.dateSourceRaw == nil {
                    return true
                }
                return existing.contentModificationDate != file.modificationDate
            }
            return true
        }

        // 3. Extract metadata concurrently and apply it in batches. Each saved
        //    batch is published immediately so the grid fills during the scan.
        await progress?(ScanProgress(phase: .indexing, completed: 0, total: filesNeedingMetadata.count))
        let applyInterval = Perf.begin("scan.applyBatches")
        let chunks = filesNeedingMetadata.chunked(into: Self.maxConcurrentExtractions)
        var pending: [(FileToIndex, ExtractedMetadata)] = []
        pending.reserveCapacity(Self.applyBatchSize)
        var publishedCount = 0

        for (chunkIndex, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            pending.append(contentsOf: await extractMetadata(for: chunk))

            let isLastChunk = chunkIndex == chunks.count - 1
            if pending.count >= Self.applyBatchSize || isLastChunk {
                let batch = try await applyMetadataBatch(pending, itemsByPath: itemsByPath)
                for (path, entity) in batch.newEntities {
                    itemsByPath[path] = entity
                }
                publishedCount += batch.items.count
                await indexed?(batch.items)
                await progress?(ScanProgress(phase: .indexing, completed: publishedCount, total: filesNeedingMetadata.count))
                pending.removeAll(keepingCapacity: true)
            }
        }
        Perf.end(applyInterval, "changed=\(filesNeedingMetadata.count) published=\(publishedCount)")
        try Task.checkCancellation()

        // 4. Apply deletions in a final save. A cancelled scan keeps everything
        //    that was already indexed; the next scan finishes reconciliation.
        let removedPaths = Set(itemsByPath.keys).subtracting(discoveredRelativePaths)
        await progress?(ScanProgress(phase: .saving, completed: publishedCount, total: filesNeedingMetadata.count))
        let saveInterval = Perf.begin("scan.save")
        try await context.perform {
            let thumbnailGenerator = ThumbnailGenerator.shared
            for path in removedPaths {
                if let entity = itemsByPath[path] {
                    let input = ThumbnailInput(
                        relativePath: entity.relativePath,
                        modificationDate: entity.contentModificationDate,
                        mediaType: entity.mediaType
                    )
                    thumbnailGenerator.removeThumbnails(for: input, rootURL: rootURL)
                    self.context.delete(entity)
                }
            }

            try self.context.save()
        }
        Perf.end(saveInterval, "processed=\(publishedCount) removed=\(removedPaths.count)")

        return ScanResult(processed: publishedCount, removed: removedPaths.count)
    }

    /// Extract metadata for one chunk with bounded task-group concurrency.
    private func extractMetadata(for files: [FileToIndex]) async -> [(FileToIndex, ExtractedMetadata)] {
        await withTaskGroup(of: (FileToIndex, ExtractedMetadata).self) { group in
            for file in files {
                group.addTask {
                    let metadata = self.metadataExtractor.extract(from: file.url)
                    return (file, metadata)
                }
            }
            var collected: [(FileToIndex, ExtractedMetadata)] = []
            collected.reserveCapacity(files.count)
            for await result in group {
                collected.append(result)
            }
            return collected
        }
    }

    /// Insert/update one batch and save it. Returns UI snapshots plus entities
    /// created here so later batches can update them without re-fetching.
    private func applyMetadataBatch(
        _ batch: [(FileToIndex, ExtractedMetadata)],
        itemsByPath: [String: MediaItemEntity]
    ) async throws -> (items: [MediaItem], newEntities: [(String, MediaItemEntity)]) {
        try await context.perform {
            var entities: [MediaItemEntity] = []
            entities.reserveCapacity(batch.count)
            var newEntities: [(String, MediaItemEntity)] = []

            for (file, metadata) in batch {
                let entity: MediaItemEntity
                if let existing = itemsByPath[file.relativePath] {
                    entity = existing
                } else {
                    entity = MediaItemEntity(context: self.context)
                    entity.relativePath = file.relativePath
                    newEntities.append((file.relativePath, entity))
                }

                entity.fileName = file.url.lastPathComponent
                entity.fileSize = file.fileSize
                entity.contentModificationDate = file.modificationDate
                entity.derivedDate = metadata.derivedDate
                // A sentinel distinguishes "processed, no trustworthy date"
                // from a row created before batch 13 (where dateSource is nil).
                entity.dateSourceRaw = metadata.dateSource?.rawValue ?? "unknown"
                // Keep the legacy column populated for older store readers.
                entity.creationDate = metadata.derivedDate
                entity.coordinate = metadata.coordinate
                entity.mediaType = metadata.mediaType
                entity.thumbnailPath = nil

                if let coordinate = metadata.coordinate {
                    entity.locationName = GeocoderService.shared.cachedName(for: coordinate, in: self.context)
                } else {
                    entity.locationName = nil
                }
                entities.append(entity)
            }

            try self.context.save()
            return (entities.map(MediaItem.init(entity:)), newEntities)
        }
    }

    private func fetchAllItems() throws -> [MediaItemEntity] {
        let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
        request.returnsObjectsAsFaults = true
        return try context.fetch(request)
    }

    private static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "mp4", "mov"].contains(ext)
    }
}

enum ScanError: Error {
    case enumerationFailed
}

struct ScanResult {
    let processed: Int
    let removed: Int
}

private struct FileToIndex {
    let url: URL
    let relativePath: String
    let modificationDate: Date
    let fileSize: Int64
}

private extension URL {
    func path(relativeTo base: URL) -> String {
        let path = self.path
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        if path.hasPrefix(basePath) {
            return String(path.dropFirst(basePath.count))
        }
        return path
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}


struct ScanProgress: Sendable {
    enum Phase: String, Sendable {
        case enumerating
        case indexing
        case saving
    }

    let phase: Phase
    let completed: Int
    let total: Int
}
