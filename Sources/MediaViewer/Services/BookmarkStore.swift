import Foundation

enum BookmarkStoreError: Error {
    case noBookmarkStored
    case failedToResolve(Error)
    case bookmarkStale
}

final class BookmarkStore {
    static let shared = BookmarkStore()
    private let key = "mediaViewerRootBookmark"

    func saveBookmark(for url: URL) throws {
        let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: key)
    }

    func loadRootURL() throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: key) else {
            throw BookmarkStoreError.noBookmarkStored
        }

        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale {
                throw BookmarkStoreError.bookmarkStale
            }
            return url
        } catch {
            throw BookmarkStoreError.failedToResolve(error)
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

extension URL {
    /// Convenience wrapper for scoped resource access.
    func withSecurityScope<T>(_ action: () throws -> T) rethrows -> T {
        let started = self.startAccessingSecurityScopedResource()
        defer {
            if started { self.stopAccessingSecurityScopedResource() }
        }
        return try action()
    }

    func withSecurityScope<T>(_ action: () async throws -> T) async rethrows -> T {
        let started = self.startAccessingSecurityScopedResource()
        defer {
            if started { self.stopAccessingSecurityScopedResource() }
        }
        return try await action()
    }
}
