import Foundation
import XCTest
@testable import MediaViewer

final class DirectoryFingerprintTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DirectoryFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, data: Data = Data("x".utf8)) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    func testUnchangedDirectoriesSkipAndFileAddChangesParent() async throws {
        try write("a/one.jpg")
        try write("a/b/two.jpg")
        try write("c/three.jpg")

        let first = try await DirectoryFingerprintWalker.walk(rootURL: root, previous: nil)
        XCTAssertEqual(first.directories.count, 4)
        XCTAssertEqual(first.changedDirectories.count, 4)
        XCTAssertEqual(first.skippedDirectories, 0)

        let snapshot = DirectoryFingerprintSnapshot(
            version: DirectoryFingerprintSnapshot.currentVersion,
            lastFullScan: Date(),
            dateMigrationVersion: DirectoryFingerprintSnapshot.currentDateMigrationVersion,
            directories: first.directories
        )
        let unchanged = try await DirectoryFingerprintWalker.walk(rootURL: root, previous: snapshot)
        XCTAssertEqual(unchanged.changedDirectories, [])
        XCTAssertEqual(unchanged.skippedDirectories, 4)

        try write("a/four.jpg")
        let added = try await DirectoryFingerprintWalker.walk(rootURL: root, previous: snapshot)
        XCTAssertTrue(added.changedDirectories.contains("a"))
        XCTAssertFalse(added.changedDirectories.contains("c"))
        XCTAssertGreaterThanOrEqual(added.skippedDirectories, 1)

        try FileManager.default.removeItem(at: root.appendingPathComponent("a/four.jpg"))
        let removed = try await DirectoryFingerprintWalker.walk(rootURL: root, previous: snapshot)
        XCTAssertTrue(removed.changedDirectories.contains("a"))
        XCTAssertFalse(removed.changedDirectories.contains("c"))
    }

    func testFingerprintStoreRoundTrip() throws {
        let directory = root.appendingPathComponent("store", isDirectory: true)
        let store = DirectoryFingerprintStore(url: directory.appendingPathComponent("f.json"))
        let snapshot = DirectoryFingerprintSnapshot(
            version: DirectoryFingerprintSnapshot.currentVersion,
            lastFullScan: Date(timeIntervalSince1970: 1_700_000_000),
            dateMigrationVersion: DirectoryFingerprintSnapshot.currentDateMigrationVersion,
            directories: [
                ".": DirectoryFingerprint(
                    path: ".",
                    modificationTime: 1_700_000_000,
                    entryCount: 1,
                    subdirectoryCount: 0
                )
            ]
        )
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }
}
