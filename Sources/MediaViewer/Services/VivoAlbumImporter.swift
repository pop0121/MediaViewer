import CoreData
import Foundation
import SQLite3

/// Reads album structure from vivo 办公套件 (pcsuite) local caches and stores
/// it on the media index.
///
/// vivo 办公套件 has no public API; the only usable local artifact is its
/// transfer log, `~/Library/Application Support/pcsuite/database/TransferRecord.db`,
/// which records `phonePath` (full path on the phone) and `savePath` (where the
/// file landed on this Mac) for every file dragged/exported through the suite.
/// On vivo phones an album is backed by a directory, so the parent directory
/// of `phonePath` is the album name. Files exported outside the suite (e.g. a
/// flattened one-shot export) leave no record and cannot be recovered here.
///
/// The importer owns `albumNamesRaw` wholesale: every run recomputes the stored
/// names for every indexed file and is therefore idempotent.
enum VivoAlbumImportOutcome {
    case imported(matchedItems: Int, albumCount: Int)
    /// TransferRecord.db not found and no bookmarked copy.
    case notFound
    /// The database exists but cannot be read (app sandbox denies access to
    /// another app's data without an explicit user grant).
    case accessDenied
    case failed(String)
}

struct VivoAlbumImporter {
    private static let defaultRelativePath = "Library/Application Support/pcsuite/database/TransferRecord.db"
    private static let bookmarkKey = "pcsuiteDatabaseBookmark"

    private let databaseURL: URL?

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            self.databaseURL = Self.resolveDatabaseURL()
        }
    }

    /// Import albums into the index. On success returns a per-item map of the
    /// *stored* (vivo) album names so the caller can refresh in-memory items
    /// without a full refetch.
    @MainActor
    func importIfAvailable(persistence: PersistenceController, rootURL: URL) async -> (VivoAlbumImportOutcome, [String: [String]]) {
        guard let databaseURL else {
            return (.notFound, [:])
        }
        // A bookmark can outlive the file; distinguish "gone" from "blocked".
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return (.notFound, [:])
        }
        let albumBySavePath: [String: Set<String>]
        do {
            albumBySavePath = try Self.readAlbumsBySavePath(from: databaseURL)
        } catch let error as VivoAlbumImportError where error == .openDenied {
            return (.accessDenied, [:])
        } catch {
            return (.failed(error.localizedDescription), [:])
        }
        // The importer owns albumNamesRaw wholesale, so even an empty transfer
        // log must clear previously stored names. No early return here.

        let context = persistence.container.newBackgroundContext()
        do {
            return try await context.perform {
                let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
                request.returnsObjectsAsFaults = true
                let entities = try context.fetch(request)

                let rootPrefix = rootURL.standardizedFileURL.path.hasSuffix("/")
                    ? rootURL.standardizedFileURL.path
                    : rootURL.standardizedFileURL.path + "/"
                var storedByRelativePath: [String: [String]] = [:]
                var matched = 0
                for entity in entities {
                    guard let stored = self.matchAlbums(for: entity, rootPrefix: rootPrefix, albumBySavePath: albumBySavePath) else {
                        // The importer owns the column: clear names that no
                        // longer match any transfer record.
                        if !entity.storedAlbumNames.isEmpty {
                            entity.storedAlbumNames = []
                        }
                        continue
                    }
                    matched += 1
                    entity.storedAlbumNames = stored
                    storedByRelativePath[entity.relativePath] = stored
                }
                try context.save()

                let albumCount = Set(albumBySavePath.values.flatMap { $0 }).count
                Log.library.notice(
                    "vivo album import matched=\(matched) indexed=\(entities.count) albums=\(albumCount)"
                )
                return (.imported(matchedItems: matched, albumCount: albumCount), storedByRelativePath)
            }
        } catch {
            return (.failed(error.localizedDescription), [:])
        }
    }

    private func matchAlbums(
        for entity: MediaItemEntity,
        rootPrefix: String,
        albumBySavePath: [String: Set<String>]
    ) -> [String]? {
        // Save paths in TransferRecord.db are absolute Mac paths; index paths
        // are relative to the library root.
        let absolute = rootPrefix + entity.relativePath
        guard let albums = albumBySavePath[absolute] ?? albumBySavePath[Self.normalizing(absolute)] else {
            return nil
        }
        return albums.sorted()
    }

    /// savePath strings occasionally carry double slashes; standardize so the
    /// string match survives them.
    private static func normalizing(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    // MARK: - Reading TransferRecord.db

    private enum VivoAlbumImportError: Error {
        case openDenied
    }

    /// Build `[savePath: album names]` from the transfer log. Rows without a
    /// phone path (folder-level aggregates) carry no album information.
    private static func readAlbumsBySavePath(from url: URL) throws -> [String: Set<String>] {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        // Immutable=1 tells SQLite the file cannot change underneath us; it
        // also lets a sandboxed reader open a file it could not otherwise lock.
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string,
              sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw VivoAlbumImportError.openDenied
        }
        defer { sqlite3_close(handle) }

        let sql = "SELECT phonePath, savePath FROM TransferRecord WHERE phonePath <> '' AND savePath <> ''"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VivoAlbumImportError.openDenied
        }
        defer { sqlite3_finalize(statement) }

        var result: [String: Set<String>] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let phonePath = Self.columnText(statement, index: 0),
                  let savePath = Self.columnText(statement, index: 1) else {
                continue
            }
            let parent = (phonePath as NSString).deletingLastPathComponent as NSString
            let album = parent.lastPathComponent
            guard !album.isEmpty, album != "/" else { continue }
            result[Self.normalizing(savePath), default: []].insert(album)
        }
        return result
    }

    private static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    // MARK: - Database location

    private static func resolveDatabaseURL() -> URL? {
        // A user-granted bookmark (sandboxed builds) wins over the default path.
        if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withSecurityScope,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home.appendingPathComponent(defaultRelativePath)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Persist a user-picked TransferRecord.db (NSOpenPanel) for sandboxed use.
    static func storeBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }
}
