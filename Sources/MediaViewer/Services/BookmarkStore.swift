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
            // Security-scoped bookmarks are bound to the signing identity that
            // created them. A dev binary (`swift run`, ad-hoc cdhash different
            // from the bundled app's) cannot resolve another build's scoped
            // bookmark; fall back to a plain resolution, which still yields a
            // usable URL outside the app sandbox.
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: .withoutUI,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale) {
                return url
            }
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
