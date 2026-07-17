import Foundation
import CoreLocation

struct MediaItem: Identifiable {
    let id: String
    let relativePath: String
    let fileName: String
    let fileSize: Int64
    let contentModificationDate: Date
    let creationDate: Date?
    let coordinate: CLLocationCoordinate2D?
    let locationName: String?
    let mediaType: MediaType
    let thumbnailPath: String?

    var url: URL? {
        // Resolved lazily against the current root URL by the caller.
        nil
    }

    var isVideo: Bool { mediaType == .video }
    var isPhoto: Bool { mediaType == .photo }

    enum MediaType: String, Hashable {
        case photo
        case video
    }
}

extension MediaItem: Equatable {
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension MediaItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension MediaItem {
    /// A display title for the item.
    var displayName: String {
        fileName
    }

    /// A formatted creation date string for tooltips/overlays.
    var formattedDate: String? {
        guard let creationDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: creationDate)
    }
}
