import CoreData
import Foundation

final class MediaScanner {
    static let hiddenDirectoryName = ".mediaviewer"

    /// Maximum number of files whose metadata is extracted concurrently.
    /// This keeps memory reasonable while still saturating I/O for video metadata.
    private static let maxConcurrentExtractions = 8

    private let context: NSManagedObjectContext
    private let metadataExtractor = MetadataExtractor()

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    /// Scan the root URL and update the Core Data index. Returns the number of new/changed items processed.
    func scan(rootURL: URL) async throws -> ScanResult {
        try await self._scan(rootURL: rootURL)
    }

    private func _scan(rootURL: URL) async throws -> ScanResult {
        let fileManager = FileManager.default

        // 1. Enumerate the filesystem and collect files that need (re)indexing.
        var discoveredRelativePaths = Set<String>()
        var changedFiles: [FileToIndex] = []

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                print("Enumerator error at \(url): \(error.localizedDescription)")
                return true
            }
        ) else {
            throw ScanError.enumerationFailed
        }

        while let fileURL = enumerator.nextObject() as? URL {
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

        // 2. Load the existing index so we can skip unchanged files quickly.
        let existingItems = try await context.perform {
            try self.fetchAllItems()
        }
        var itemsByPath: [String: MediaItemEntity] = [:]
        for item in existingItems {
            itemsByPath[item.relativePath] = item
        }

        // Filter to only files whose modification date differs.
        let filesNeedingMetadata = changedFiles.filter { file in
            if let existing = itemsByPath[file.relativePath] {
                return existing.contentModificationDate != file.modificationDate
            }
            return true
        }

        // 3. Extract metadata concurrently with bounded parallelism.
        let extractedMetadata = try await extractMetadataConcurrently(
            files: filesNeedingMetadata,
            limit: Self.maxConcurrentExtractions
        )

        // 4. Apply all updates in a single Core Data perform block.
        let processed = extractedMetadata.count
        try await context.perform {
            for (file, metadata) in extractedMetadata {
                let entity: MediaItemEntity
                if let existing = itemsByPath[file.relativePath] {
                    entity = existing
                } else {
                    entity = MediaItemEntity(context: self.context)
                    entity.relativePath = file.relativePath
                }

                entity.fileName = file.url.lastPathComponent
                entity.fileSize = file.fileSize
                entity.contentModificationDate = file.modificationDate
                entity.creationDate = metadata.creationDate
                entity.coordinate = metadata.coordinate
                entity.mediaType = metadata.mediaType
                entity.thumbnailPath = nil

                if let coordinate = metadata.coordinate {
                    entity.locationName = GeocoderService.shared.cachedName(for: coordinate, in: self.context)
                } else {
                    entity.locationName = nil
                }
            }

            // Remove entries for deleted files.
            let removedPaths = Set(itemsByPath.keys).subtracting(discoveredRelativePaths)
            let thumbnailGenerator = ThumbnailGenerator.shared
            for path in removedPaths {
                if let entity = itemsByPath[path] {
                    let input = ThumbnailInput(
                        relativePath: entity.relativePath,
                        modificationDate: entity.contentModificationDate,
                        mediaType: entity.mediaType
                    )
                    if let thumbURL = thumbnailGenerator.thumbnailURL(for: input, rootURL: rootURL) {
                        try? fileManager.removeItem(at: thumbURL)
                    }
                    self.context.delete(entity)
                }
            }

            try self.context.save()
        }

        // 5. Generate thumbnails for changed/new files outside the Core Data context.
        let thumbnailInputs = extractedMetadata.map { (file, metadata) in
            ThumbnailInput(
                relativePath: file.relativePath,
                modificationDate: file.modificationDate,
                mediaType: metadata.mediaType
            )
        }
        await ThumbnailGenerator.shared.generateThumbnails(
            for: thumbnailInputs,
            rootURL: rootURL,
            maxConcurrent: Self.maxConcurrentExtractions
        )

        return ScanResult(processed: processed, removed: discoveredRelativePaths.count + itemsByPath.count - processed)
    }

    /// Extract metadata for many files concurrently, but never more than `limit` at a time.
    private func extractMetadataConcurrently(
        files: [FileToIndex],
        limit: Int
    ) async throws -> [(FileToIndex, ExtractedMetadata)] {
        var results: [(FileToIndex, ExtractedMetadata)] = []
        results.reserveCapacity(files.count)

        // Process in sliding windows to bound memory and AVAsset concurrency.
        let chunks = files.chunked(into: limit)
        for chunk in chunks {
            let chunkResults = await withTaskGroup(of: (FileToIndex, ExtractedMetadata).self) { group in
                for file in chunk {
                    group.addTask {
                        let metadata = self.metadataExtractor.extract(from: file.url)
                        return (file, metadata)
                    }
                }
                var collected: [(FileToIndex, ExtractedMetadata)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected
            }
            results.append(contentsOf: chunkResults)
        }

        return results
    }

    private func fetchAllItems() throws -> [MediaItemEntity] {
        let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
        request.returnsObjectsAsFaults = true
        return try context.fetch(request)
    }

    private static func isMediaFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "mp4", "mov"].contains(ext)
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
