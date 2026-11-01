import CoreData
import Foundation
import XCTest
@testable import MediaViewer

final class MediaScannerIncrementalTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!
    private var fingerprintURL: URL!
    private var controller: PersistenceController!

    override func setUpWithError() throws {
        let temp = FileManager.default.temporaryDirectory
        root = URL(fileURLWithPath: "/private\(temp.path)")
            .appendingPathComponent("MediaScannerIncrementalTests-\(UUID().uuidString)", isDirectory: true)
        storeURL = root.appendingPathComponent("index.sqlite")
        fingerprintURL = root.appendingPathComponent("fingerprints.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeURL = root.appendingPathComponent("index.sqlite")
        fingerprintURL = root.appendingPathComponent("fingerprints.json")
        controller = try PersistenceController(storeURL: storeURL)
    }

    override func tearDownWithError() throws {
        controller = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-really-jpeg".utf8).write(to: url)
    }

    private func scan() async throws -> ScanResult {
        let context = controller.container.newBackgroundContext()
        let scanner = MediaScanner(
            context: context,
            fingerprintStore: DirectoryFingerprintStore(url: fingerprintURL)
        )
        return try await scanner.scan(rootURL: root)
    }

    private func itemCount() async throws -> Int {
        let context = controller.container.viewContext
        return try await context.perform {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            return try context.count(for: request)
        }
    }

    func testIncrementalScanSeesAddedAndRemovedFiles() async throws {
        try write("one/a.jpg")
        try write("two/b.jpg")
        let first = try await scan()
        XCTAssertTrue(first.fullScan)
        let firstCount = try await itemCount()
        XCTAssertEqual(firstCount, 2)
        let dated = try await controller.container.viewContext.perform {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            return try self.controller.container.viewContext.fetch(request)
        }
        XCTAssertTrue(dated.allSatisfy { $0.derivedDate != nil && $0.dateSource != nil })

        let hot = try await scan()
        XCTAssertFalse(hot.fullScan)
        XCTAssertEqual(hot.processed, 0)
        XCTAssertGreaterThanOrEqual(hot.skippedDirectories, 2)
        let hotCount = try await itemCount()
        XCTAssertEqual(hotCount, 2)

        try write("two/c.jpg")
        let added = try await scan()
        XCTAssertFalse(added.fullScan)
        XCTAssertEqual(added.processed, 1)
        let count3 = try await itemCount()
        XCTAssertEqual(count3, 3)

        try FileManager.default.removeItem(at: root.appendingPathComponent("two/c.jpg"))
        let removed = try await scan()
        XCTAssertFalse(removed.fullScan)
        XCTAssertEqual(removed.removed, 1)
        let finalCount = try await itemCount()
        XCTAssertEqual(finalCount, 2)
    }

    func testStaleFullScanForcesFullScan() async throws {
        try write("a.jpg")
        _ = try await scan()
        let store = DirectoryFingerprintStore(url: fingerprintURL)
        var snapshot = try XCTUnwrap(store.load())
        snapshot.lastFullScan = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
        try store.save(snapshot)
        let result = try await scan()
        XCTAssertTrue(result.fullScan)
    }

    func testDeletedFingerprintForcesFullScan() async throws {
        try write("a.jpg")
        _ = try await scan()
        try FileManager.default.removeItem(at: fingerprintURL)
        let result = try await scan()
        XCTAssertTrue(result.fullScan)
        let count1 = try await itemCount()
        XCTAssertEqual(count1, 1)
        let rows = try await controller.container.viewContext.perform {
            let request = NSFetchRequest<MediaItemEntity>(entityName: "MediaItemEntity")
            return try self.controller.container.viewContext.fetch(request)
        }
        XCTAssertTrue(rows.allSatisfy { $0.derivedDate != nil && $0.dateSource != nil })
    }
}
