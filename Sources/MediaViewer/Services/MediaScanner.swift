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
    private let injectedFingerprintStore: DirectoryFingerprintStore?

    init(context: NSManagedObjectContext, fingerprintStore: DirectoryFingerprintStore? = nil) {
        self.context = context
        self.injectedFingerprintStore = fingerprintStore
    }

    /// Scan the root URL and update the Core Data index. Returns the number of new/changed items processed.
    func scan(
        rootURL: URL,
        forceFullScan: Bool = false,
        progress: (@Sendable (ScanProgress) async -> Void)? = nil,
        indexed: (@Sendable ([MediaItem]) async -> Void)? = nil
    ) async throws -> ScanResult {
        try await self._scan(
            rootURL: rootURL,
            forceFullScan: forceFullScan,
            progress: progress,
            indexed: indexed
        )
    }

    private func _scan(
        rootURL: URL,
        forceFullScan: Bool,
        progress: (@Sendable (ScanProgress) async -> Void)?,
        indexed: (@Sendable ([MediaItem]) async -> Void)?
    ) async throws -> ScanResult {
        let fingerprintStore = injectedFingerprintStore
            ?? DirectoryFingerprintStore(rootURL: rootURL)
        let previousSnapshot = fingerprintStore.load()

        // 1. Load the existing index once. Empty date-source columns mean the
        // batch-13 migration has not completed; that is a one-time full pass.
        let fetchIndexInterval = Perf.begin("scan.fetchIndex")
        let existingItems = try await context.perform {
            try self.fetchAllItems()
        }
        Perf.end(fetchIndexInterval, "rows=\(existingItems.count)")

        var itemsByPath: [String: MediaItemEntity] = [:]
        itemsByPath.reserveCapacity(existingItems.count)
        for item in existingItems {
            itemsByPath[item.relativePath] = item
        }

        let needsDateMigration = existingItems.contains { $0.dateSourceRaw == nil }
        let fingerprintMissing = previousSnapshot == nil
        let fingerprintVersionMismatch = previousSnapshot.map {
            $0.version != DirectoryFingerprintSnapshot.currentVersion
        } ?? false
        let staleFullScan = previousSnapshot.map {
            Date().timeIntervalSince($0.lastFullScan) >= 7 * 24 * 60 * 60
        } ?? true
        let fullScan = forceFullScan
            || fingerprintMissing
            || fingerprintVersionMismatch
            || staleFullScan
            || needsDateMigration
            || (previousSnapshot?.dateMigrationVersion ?? 0)
                < DirectoryFingerprintSnapshot.currentDateMigrationVersion

        // 2. Directory-only walk. readdir's d_type avoids a stat per media file;
        // only directory mtimes are read. Unchanged directories are skipped.
        let fingerprintInterval = Perf.begin("scan.directoryFingerprints")
        let walked = try await DirectoryFingerprintWalker.walk(
            rootURL: rootURL,
            previous: fullScan ? nil : previousSnapshot
        )
        Perf.end(
            fingerprintInterval,
            "full=\(fullScan) dirs=\(walked.directories.count) changedDirs=\(walked.changedDirectories.count) skippedDirs=\(walked.skippedDirectories)"
        )
        await progress?(ScanProgress(
            phase: .comparingDirectories,
            completed: walked.directories.count,
            total: walked.directories.count,
            directoriesScanned: walked.directories.count,
            directoriesTotal: walked.directories.count,
            directoriesSkipped: walked.skippedDirectories
        ))
        try Task.checkCancellation()

        var changedFiles: [FileToIndex] = []
        var discoveredRelativePaths = Set<String>()

        if fullScan {
            // Full reconciliation: stat every media file once. This is the
            // >7-day/manual/upgrade fallback and also rebuilds fingerprints.
            let enumerated = try await enumerateAllMedia(
                rootURL: rootURL,
                progress: progress
            )
            changedFiles = enumerated.files
            discoveredRelativePaths = enumerated.paths
        } else {
            let previousDirectories = Set(walked.directories.keys)
            let trustedDirectories = previousDirectories.subtracting(walked.changedDirectories)

            // Reuse index rows under unchanged directories without touching
            // their files. They are still part of the live set for deletion.
            for path in itemsByPath.keys where trustedDirectories.contains(Self.parentPath(of: path)) {
                discoveredRelativePaths.insert(path)
            }

            // Only directories whose fingerprint changed need per-file stat.
            for directoryPath in walked.changedDirectories {
                guard let node = walked.nodes[directoryPath] else { continue }
                for fileURL in DirectoryFingerprintWalker.files(in: node) {
                    guard Self.isMediaFile(fileURL) else { continue }
                    let relativePath = fileURL.path(relativeTo: rootURL)
                    discoveredRelativePaths.insert(relativePath)
                    let values = try? fileURL.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey]
                    )
                    changedFiles.append(FileToIndex(
                        url: fileURL,
                        relativePath: relativePath,
                        modificationDate: values?.contentModificationDate ?? Date.distantPast,
                        fileSize: Int64(values?.fileSize ?? 0)
                    ))
                }
            }
            await progress?(ScanProgress(
                phase: .enumerating,
                completed: walked.changedDirectories.count,
                total: walked.directories.count,
                directoriesScanned: walked.directories.count,
                directoriesTotal: walked.directories.count,
                directoriesSkipped: walked.skippedDirectories
            ))
        }

        // 3. Compare file mtime/size/date-source for the candidate files. In
        // incremental mode only changed directories contribute candidates.
        let diffInterval = Perf.begin("scan.diff")
        let filesNeedingMetadata = changedFiles.filter { file in
            if let existing = itemsByPath[file.relativePath] {
                // A row from before date-source support must be migrated once.
                if existing.dateSourceRaw == nil {
                    return true
                }
                if existing.contentModificationDate != file.modificationDate {
                    return true
                }
                // Size catches coarse-timestamp false negatives.
                return existing.fileSize != file.fileSize
            }
            return true
        }
        Perf.end(
            diffInterval,
            "files=\(changedFiles.count) reused=\(changedFiles.count - filesNeedingMetadata.count) metadata=\(filesNeedingMetadata.count) full=\(fullScan)"
        )

        // 4. Extract metadata concurrently and apply it in batches. Each saved
        //    batch is published immediately so the grid fills during the scan.
        await progress?(ScanProgress(
            phase: .indexing,
            completed: 0,
            total: filesNeedingMetadata.count,
            directoriesScanned: walked.directories.count,
            directoriesTotal: walked.directories.count,
            directoriesSkipped: walked.skippedDirectories
        ))
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
                await progress?(ScanProgress(
                    phase: .indexing,
                    completed: publishedCount,
                    total: filesNeedingMetadata.count,
                    directoriesScanned: walked.directories.count,
                    directoriesTotal: walked.directories.count,
                    directoriesSkipped: walked.skippedDirectories
                ))
                pending.removeAll(keepingCapacity: true)
            }
        }
        Perf.end(applyInterval, "changed=\(filesNeedingMetadata.count) published=\(publishedCount)")

        // 5. Apply deletions in a final save. Cancelled scans keep everything
        //    already indexed; the next scan finishes reconciliation.
        let removedPaths = Set(itemsByPath.keys).subtracting(discoveredRelativePaths)
        await progress?(ScanProgress(
            phase: .saving,
            completed: publishedCount,
            total: filesNeedingMetadata.count,
            directoriesScanned: walked.directories.count,
            directoriesTotal: walked.directories.count,
            directoriesSkipped: walked.skippedDirectories
        ))
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

        // 6. Persist the fingerprint cache only after the index save succeeds.
        //    A failed/cancelled scan leaves the old snapshot in place.
        let nextSnapshot = DirectoryFingerprintSnapshot(
            version: DirectoryFingerprintSnapshot.currentVersion,
            lastFullScan: fullScan ? Date() : (previousSnapshot?.lastFullScan ?? Date()),
            dateMigrationVersion: DirectoryFingerprintSnapshot.currentDateMigrationVersion,
            directories: walked.directories
        )
        do {
            try fingerprintStore.save(nextSnapshot)
        } catch {
            Log.scan.error(
                "Failed to save directory fingerprints root=\(rootURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }

        return ScanResult(
            processed: publishedCount,
            removed: removedPaths.count,
            fullScan: fullScan,
            skippedDirectories: walked.skippedDirectories,
            totalDirectories: walked.directories.count
        )
    }

    private func enumerateAllMedia(
        rootURL: URL,
        progress: (@Sendable (ScanProgress) async -> Void)?
    ) async throws -> (files: [FileToIndex], paths: Set<String>) {
        let fileManager = FileManager.default
        let enumerateInterval = Perf.begin("scan.enumerate")
        var files: [FileToIndex] = []
        var paths = Set<String>()

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
                await progress?(ScanProgress(
                    phase: .enumerating,
                    completed: enumeratedCount,
                    total: 0,
                    directoriesScanned: 0,
                    directoriesTotal: 0,
                    directoriesSkipped: 0
                ))
            }
            let relativePath = fileURL.path(relativeTo: rootURL)
            if relativePath.hasPrefix("\(Self.hiddenDirectoryName)/")
                || relativePath == Self.hiddenDirectoryName
                || relativePath.hasPrefix(".database/")
                || relativePath == ".database" {
                continue
            }
            guard Self.isMediaFile(fileURL) else { continue }
            paths.insert(relativePath)
            let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            files.append(FileToIndex(
                url: fileURL,
                relativePath: relativePath,
                modificationDate: values?.contentModificationDate ?? Date.distantPast,
                fileSize: Int64(values?.fileSize ?? 0)
            ))
        }
        Perf.end(enumerateInterval, "enumerated=\(enumeratedCount) media=\(files.count)")
        return (files, paths)
    }

    private static func parentPath(of relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
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
    let fullScan: Bool
    let skippedDirectories: Int
    let totalDirectories: Int
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
        case comparingDirectories
        case enumerating
        case indexing
        case saving
    }

    let phase: Phase
    let completed: Int
    let total: Int
    var directoriesScanned: Int = 0
    var directoriesTotal: Int = 0
    var directoriesSkipped: Int = 0
}
