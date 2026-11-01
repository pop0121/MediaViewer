import Darwin
import Foundation

/// A directory-level fingerprint. A directory's mtime changes when an entry is
/// added, removed, or renamed; the entry/subdirectory counts are a second guard
/// for filesystems with coarse timestamps.
struct DirectoryFingerprint: Codable, Equatable {
    let path: String
    let modificationTime: TimeInterval
    let entryCount: Int
    let subdirectoryCount: Int
}

struct DirectoryFingerprintSnapshot: Codable, Equatable {
    static let currentVersion = 1
    static let currentDateMigrationVersion = 13

    var version: Int
    var lastFullScan: Date
    var dateMigrationVersion: Int
    var directories: [String: DirectoryFingerprint]
}

/// Persisted next to the SQLite store. This is deliberately separate from Core
/// Data: it is a cache of filesystem observations, not user data, and can be
/// deleted to force a full scan.
final class DirectoryFingerprintStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    convenience init(rootURL: URL) {
        self.init(url: MediaStorageLocations(rootURL: rootURL)
            .storeDirectory
            .appendingPathComponent("DirectoryFingerprints.json"))
    }

    func load() -> DirectoryFingerprintSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(DirectoryFingerprintSnapshot.self, from: data),
              snapshot.version == DirectoryFingerprintSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: DirectoryFingerprintSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }
}

/// Fast directory-only walk. It uses `readdir`'s d_type to distinguish files
/// from directories on exFAT/APFS, so unchanged subtrees never incur a stat per
/// media file. Only directory mtimes are stat'ed.
enum DirectoryFingerprintWalker {
    struct Result {
        var directories: [String: DirectoryFingerprint]
        /// Directories that still need per-file inspection this pass.
        var changedDirectories: Set<String>
        var skippedDirectories: Int
        var nodes: [String: Node]
    }

    struct Node {
        let url: URL
        let relativePath: String
        let fingerprint: DirectoryFingerprint
        let fileNames: [String]
    }

    /// Walk every visible directory and compare against the previous snapshot.
    /// `changedDirectories` includes new directories and directories whose
    /// fingerprint differs. Deleted directories only disappear from the map.
    static func walk(
        rootURL: URL,
        previous: DirectoryFingerprintSnapshot?
    ) async throws -> Result {
        var directories: [String: DirectoryFingerprint] = [:]
        var nodes: [String: Node] = [:]
        try walkDirectory(
            url: rootURL,
            relativePath: ".",
            directories: &directories,
            nodes: &nodes
        )

        let old = previous?.directories ?? [:]
        var changed = Set<String>()
        for (path, fingerprint) in directories where old[path] != fingerprint {
            changed.insert(path)
        }
        // A changed/new directory means its direct files must be stat'ed. A
        // deleted directory has no files to scan; its indexed rows are removed
        // because their paths will not be re-discovered.
        let skipped = directories.keys.filter { !changed.contains($0) }.count
        return Result(
            directories: directories,
            changedDirectories: changed,
            skippedDirectories: skipped,
            nodes: nodes
        )
    }

    static func files(in directory: Node) -> [URL] {
        directory.fileNames.map { directory.url.appendingPathComponent($0) }
    }

    private static func walkDirectory(
        url: URL,
        relativePath: String,
        directories: inout [String: DirectoryFingerprint],
        nodes: inout [String: Node]
    ) throws {
        try Task.checkCancellation()

        guard let listing = readDirectory(url, relativePath: relativePath) else {
            // An unreadable directory must not silently look unchanged; mark it
            // with a unique fingerprint so the next pass retries it.
            let failed = DirectoryFingerprint(
                path: relativePath,
                modificationTime: -Double.infinity,
                entryCount: -1,
                subdirectoryCount: -1
            )
            directories[relativePath] = failed
            return
        }

        directories[relativePath] = listing.fingerprint
        nodes[relativePath] = Node(
            url: url,
            relativePath: relativePath,
            fingerprint: listing.fingerprint,
            fileNames: listing.fileNames
        )

        for child in listing.directories {
            let childURL = url.appendingPathComponent(child, isDirectory: true)
            let childPath = relativePath == "." ? child : "\(relativePath)/\(child)"
            try walkDirectory(
                url: childURL,
                relativePath: childPath,
                directories: &directories,
                nodes: &nodes
            )
        }
    }

    private struct Listing {
        let fingerprint: DirectoryFingerprint
        let fileNames: [String]
        let directories: [String]
    }

    private static func readDirectory(_ url: URL, relativePath: String) -> Listing? {
        guard let dir = opendir(url.path) else { return nil }
        defer { closedir(dir) }

        var modificationTime: TimeInterval = 0
        var info = stat()
        if stat(url.path, &info) == 0 {
            modificationTime = TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        }

        var entryCount = 0
        var subdirectoryCount = 0
        var fileNames: [String] = []
        var directories: [String] = []

        while let entry = readdir(dir) {
            var value = entry.pointee
            let name = withUnsafePointer(to: &value.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." || name.hasPrefix(".") {
                continue
            }
            entryCount += 1
            let type = Int(value.d_type)
            if type == Int(DT_DIR) {
                subdirectoryCount += 1
                directories.append(name)
            } else if type == Int(DT_REG) || type == Int(DT_LNK) {
                fileNames.append(name)
            }
        }

        let fingerprint = DirectoryFingerprint(
            path: relativePath,
            modificationTime: modificationTime,
            entryCount: entryCount,
            subdirectoryCount: subdirectoryCount
        )
        return Listing(
            fingerprint: fingerprint,
            fileNames: fileNames,
            directories: directories
        )
    }
}
