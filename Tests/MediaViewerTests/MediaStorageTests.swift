import CryptoKit
import XCTest
@testable import MediaViewer

final class MediaStorageTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testMigratesLegacyStoreAndLeavesLegacyBytesUntouched() throws {
        let root = tempDirectory.appendingPathComponent("root", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent(".mediaviewer/Store", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyStoreURL = legacyDirectory.appendingPathComponent(MediaStorageLocations.storeFileName)

        _ = try PersistenceController(storeURL: legacyStoreURL)
        let before = try digest(of: legacyStoreURL)

        let support = tempDirectory.appendingPathComponent("support", isDirectory: true)
        let opened = try PersistenceController.openForRoot(root, storageBase: support)
        XCTAssertEqual(opened.outcome, .migrated)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MediaStorageLocations(rootURL: root, applicationSupportBase: support).storeURL.path
        ))
        XCTAssertEqual(try digest(of: legacyStoreURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    func testCorruptLegacyStoreRebuildsAndLeavesLegacyBytesUntouched() throws {
        let root = tempDirectory.appendingPathComponent("root", isDirectory: true)
        let legacyDirectory = root.appendingPathComponent(".mediaviewer/Store", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyStoreURL = legacyDirectory.appendingPathComponent(MediaStorageLocations.storeFileName)
        try Data("this is not a sqlite database".utf8).write(to: legacyStoreURL)
        let before = try digest(of: legacyStoreURL)

        let support = tempDirectory.appendingPathComponent("support", isDirectory: true)
        let opened = try PersistenceController.openForRoot(root, storageBase: support)
        XCTAssertEqual(opened.outcome, .rebuiltAfterFailure)
        XCTAssertEqual(try digest(of: legacyStoreURL), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))

        let locations = MediaStorageLocations(rootURL: root, applicationSupportBase: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.storeURL.path))
    }

    func testApplicationSupportPathUsesStableRootHash() throws {
        let first = MediaStorageLocations(rootURL: URL(fileURLWithPath: "/tmp/Library"))
        let second = MediaStorageLocations(rootURL: URL(fileURLWithPath: "/tmp/Library/"))
        XCTAssertEqual(first.rootHash, second.rootHash)
        XCTAssertEqual(first.rootHash.count, 16)
        XCTAssertEqual(first.rootDirectory.lastPathComponent, first.rootHash)
    }

    private func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
