import CryptoKit
import Darwin
import Foundation

/// Where a library's private index and thumbnails live. The user's media root
/// is only read; its old `.mediaviewer` directory is treated as legacy data and
/// never deleted.
struct MediaStorageLocations {
    static let folderName = "MediaViewer"
    static let legacyFolderName = ".mediaviewer"
    static let storeFileName = "MediaViewer.sqlite"
    static let storeFileNames = [
        storeFileName,
        "\(storeFileName)-wal",
        "\(storeFileName)-shm"
    ]

    let rootURL: URL
    let rootHash: String
    let applicationSupportBase: URL

    init(rootURL: URL, applicationSupportBase: URL? = nil) {
        let standardized = rootURL.standardizedFileURL
        self.rootURL = standardized
        self.rootHash = Self.hash(for: standardized)
        self.applicationSupportBase = applicationSupportBase
            ?? Self.defaultApplicationSupportBase()
    }

    var rootDirectory: URL {
        applicationSupportBase.appendingPathComponent(rootHash, isDirectory: true)
    }

    var storeDirectory: URL {
        rootDirectory.appendingPathComponent("Store", isDirectory: true)
    }

    var storeURL: URL {
        storeDirectory.appendingPathComponent(Self.storeFileName)
    }

    var thumbnailsDirectory: URL {
        rootDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    var legacyDirectory: URL {
        rootURL.appendingPathComponent(Self.legacyFolderName, isDirectory: true)
    }

    var legacyStoreDirectory: URL {
        legacyDirectory.appendingPathComponent("Store", isDirectory: true)
    }

    var legacyStoreURL: URL {
        legacyStoreDirectory.appendingPathComponent(Self.storeFileName)
    }

    var legacyThumbnailsDirectory: URL {
        legacyDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    var hasLegacyStore: Bool {
        FileManager.default.fileExists(atPath: legacyStoreURL.path)
    }

    var hasNewStore: Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    func createDirectories() throws {
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try FileManager.default.createDirectory(
            at: thumbnailsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Delete only the new, app-support store. The legacy directory is never
    /// touched, even when the copy turns out to be unusable.
    func removeNewStoreArtifacts() throws {
        let fileManager = FileManager.default
        for name in Self.storeFileNames {
            let url = storeDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    /// Copy SQLite plus its WAL/SHM sidecars into the new store directory.
    /// Returns false and leaves a clean new store directory when any copy fails.
    func copyLegacyStore() -> Bool {
        let fileManager = FileManager.default
        do {
            try createDirectories()
            try removeNewStoreArtifacts()
            for name in Self.storeFileNames {
                let source = legacyStoreDirectory.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = storeDirectory.appendingPathComponent(name)
                try fileManager.copyItem(at: source, to: destination)
            }
            return true
        } catch {
            Log.scan.error(
                "Legacy store copy failed root=\(self.rootURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            try? removeNewStoreArtifacts()
            return false
        }
    }

    /// Legacy thumbnails are reused lazily on APFS: `ThumbnailGenerator`
    /// copies one file when its new-path equivalent is first requested.
    func legacyThumbnailURL(named name: String) -> URL? {
        guard fileSystemType == "apfs" else { return nil }
        let url = legacyThumbnailsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var fileSystemType: String? {
        var info = statfs()
        guard statfs(rootURL.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    static func defaultApplicationSupportBase() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    static func hash(for rootURL: URL) -> String {
        let digest = SHA256.hash(data: Data(rootURL.standardizedFileURL.path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }
}

enum MediaStorageOpenOutcome: String {
    case fresh
    case existing
    case migrated
    case rebuiltAfterFailure
}

extension PersistenceController {
    /// Open the index for a media root in Application Support.
    ///
    /// Migration is deliberately one-way: a legacy SQLite file is copied into
    /// the new location, then opened. If the copy cannot be opened it is
    /// discarded and a new store is created; `<root>/.mediaviewer` is never
    /// modified or removed.
    static func openForRoot(
        _ rootURL: URL,
        storageBase: URL? = nil
    ) throws -> (controller: PersistenceController, outcome: MediaStorageOpenOutcome) {
        let locations = MediaStorageLocations(rootURL: rootURL, applicationSupportBase: storageBase)
        try locations.createDirectories()

        if locations.hasNewStore {
            let controller = try PersistenceController(storeURL: locations.storeURL)
            return (controller, .existing)
        }

        let hasLegacyStore = locations.hasLegacyStore
        let copied = hasLegacyStore ? locations.copyLegacyStore() : false

        do {
            let controller = try PersistenceController(storeURL: locations.storeURL)
            if copied {
                Log.library.notice(
                    "Migrated legacy store root=\(rootURL.path, privacy: .public) dest=\(locations.storeURL.path, privacy: .public)"
                )
                return (controller, .migrated)
            }
            if hasLegacyStore {
                Log.library.error(
                    "Legacy store existed but copy failed; rebuilt index root=\(rootURL.path, privacy: .public)"
                )
                return (controller, .rebuiltAfterFailure)
            }
            return (controller, .fresh)
        } catch {
            let firstError = error as NSError
            guard copied else {
                throw error
            }

            // The copied store is unusable. Remove only the app-support
            // half-product and open a fresh store; the legacy directory is
            // still untouched.
            Log.library.error(
                "Migrated store failed to open; rebuilding root=\(rootURL.path, privacy: .public) domain=\(firstError.domain, privacy: .public) code=\(firstError.code)"
            )
            try locations.removeNewStoreArtifacts()
            let controller = try PersistenceController(storeURL: locations.storeURL)
            Log.library.notice(
                "Rebuilt empty index after migration failure root=\(rootURL.path, privacy: .public)"
            )
            return (controller, .rebuiltAfterFailure)
        }
    }
}

enum MediaErrorDescription {
    /// Stable diagnostic string for logs and the alert body. Includes the
    /// underlying NSError domain/code and the affected path instead of only
    /// `localizedDescription` ("permission").
    static func details(_ error: Error, rootURL: URL? = nil) -> String {
        let nsError = error as NSError
        let errorPath = (nsError.userInfo[NSFilePathErrorKey] as? String)
            ?? (nsError.userInfo[NSURLErrorKey] as? URL)?.path
            ?? rootURL?.path
            ?? "unknown"
        var value = "\(nsError.domain)(\(nsError.code)) path=\(errorPath)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            value += " underlying=\(underlying.domain)(\(underlying.code))"
        }
        return value
    }

    static func userMessage(_ error: Error, rootURL: URL) -> String {
        let nsError = error as NSError
        return """
        Scan failed: \(nsError.localizedDescription)
        Error: \(details(error, rootURL: rootURL))
        The index is stored under Application Support; the media folder was not modified. Check Console for details.
        """
    }
}
