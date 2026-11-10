import CoreData
import SQLite3
import XCTest
@testable import MediaViewer

/// VivoAlbumImporter reads pcsuite's TransferRecord.db (phonePath -> album,
/// savePath -> Mac path) and stores album names on the media index. The
/// importer must handle paths with spaces, derive the album from the phone
/// path's parent directory, and own its column wholesale (idempotent clear).
final class VivoAlbumImporterTests: XCTestCase {
    var rootDirectory: URL!
    var storeURL: URL!
    var transferDB: URL!
    var persistence: PersistenceController!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vivo-importer-tests-\(UUID().uuidString)", isDirectory: true)
        rootDirectory = base.appendingPathComponent("media root", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        storeURL = base.appendingPathComponent("MediaViewer.sqlite")
        transferDB = base.appendingPathComponent("TransferRecord.db")

        persistence = try PersistenceController(storeURL: storeURL)
        try seedIndex()
    }

    override func tearDownWithError() throws {
        persistence = nil
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    /// One photo that matches a transfer record, one stale row carrying an
    /// album that no longer matches anything (must be cleared on re-import).
    private func seedIndex() throws {
        let context = persistence.container.newBackgroundContext()
        try context.performAndWait {
            let matched = MediaItemEntity(context: context)
            matched.relativePath = "Telegram/clip.mp4"
            matched.fileName = "clip.mp4"
            matched.fileSize = 1
            matched.contentModificationDate = Date()
            matched.dateSourceRaw = "filename"
            matched.mediaType = .video

            let stale = MediaItemEntity(context: context)
            stale.relativePath = "Other/pic.jpg"
            stale.fileName = "pic.jpg"
            stale.fileSize = 1
            stale.contentModificationDate = Date()
            stale.dateSourceRaw = "filename"
            stale.mediaType = .photo
            stale.storedAlbumNames = ["Old Album"]
            try context.save()
        }
    }

    private func writeTransferDB(_ rows: [(phonePath: String, savePath: String)]) throws {
        var handle: OpaquePointer?
        let path = transferDB.path
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            XCTFail("could not create test db")
            return
        }
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE TransferRecord (id text primary key, fileName TEXT, phonePath TEXT, savePath TEXT);
        """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail("could not create schema")
            return
        }
        for (index, row) in rows.enumerated() {
            let escapedPhone = row.phonePath.replacingOccurrences(of: "'", with: "''")
            let escapedSave = row.savePath.replacingOccurrences(of: "'", with: "''")
            let insert = "INSERT INTO TransferRecord VALUES ('\(index)', 'f', '\(escapedPhone)', '\(escapedSave)');"
            guard sqlite3_exec(handle, insert, nil, nil, nil) == SQLITE_OK else {
                XCTFail("could not insert row")
                return
            }
        }
    }

    private func storedNames(for relativePath: String) throws -> [String] {
        let context = persistence.container.newBackgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            request.predicate = NSPredicate(format: "relativePath == %@", relativePath)
            let entity = try XCTUnwrap(context.fetch(request).first)
            return entity.storedAlbumNames
        }
    }

    func testImportMatchesBySavePathAndDerivesAlbumFromPhonePath() async throws {
        // The space in the media root path exercises the SQLite URI encoding.
        let savePath = rootDirectory.appendingPathComponent("Telegram/clip.mp4").path
        try writeTransferDB([
            (phonePath: "/storage/emulated/0/Movies/Telegram/clip.mp4", savePath: savePath),
        ])

        let importer = VivoAlbumImporter(databaseURL: transferDB)
        let (outcome, storedByPath) = await importer.importIfAvailable(
            persistence: persistence,
            rootURL: rootURLForTests
        )

        guard case .imported(let matched, let albumCount) = outcome else {
            XCTFail("unexpected outcome: \(outcome)")
            return
        }
        XCTAssertEqual(matched, 1)
        XCTAssertEqual(albumCount, 1)
        XCTAssertEqual(storedByPath["Telegram/clip.mp4"], ["Telegram"])
        XCTAssertEqual(try storedNames(for: "Telegram/clip.mp4"), ["Telegram"])
        // The stale album name must be cleared because no record matches.
        XCTAssertEqual(try storedNames(for: "Other/pic.jpg"), [])
    }

    func testReimportIsIdempotentAndClearsWhenRecordsDisappear() async throws {
        let savePath = rootDirectory.appendingPathComponent("Telegram/clip.mp4").path
        try writeTransferDB([
            (phonePath: "/storage/emulated/0/Movies/Telegram/clip.mp4", savePath: savePath),
        ])
        let importer = VivoAlbumImporter(databaseURL: transferDB)
        _ = await importer.importIfAvailable(persistence: persistence, rootURL: rootURLForTests)
        XCTAssertEqual(try storedNames(for: "Telegram/clip.mp4"), ["Telegram"])

        // Second run with an empty transfer log: the importer owns the column,
        // so the previously stored name must be removed.
        try FileManager.default.removeItem(at: transferDB)
        try writeTransferDB([])
        _ = await importer.importIfAvailable(persistence: persistence, rootURL: rootURLForTests)
        XCTAssertEqual(try storedNames(for: "Telegram/clip.mp4"), [])
    }

    func testMissingDatabaseReportsNotFound() async throws {
        let importer = VivoAlbumImporter(databaseURL: transferDB)
        let (outcome, storedByPath) = await importer.importIfAvailable(
            persistence: persistence,
            rootURL: rootURLForTests
        )
        guard case .notFound = outcome else {
            XCTFail("expected notFound, got \(outcome)")
            return
        }
        XCTAssertTrue(storedByPath.isEmpty)
    }

    /// The scanner builds absolute paths by concatenating the root path and
    /// the relative path with a single slash; mirror that here.
    private var rootURLForTests: URL {
        URL(fileURLWithPath: rootDirectory.path.hasSuffix("/")
            ? rootDirectory.path
            : rootDirectory.path + "/")
    }
}
