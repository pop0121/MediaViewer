import Foundation
import CoreLocation

struct MediaItem: Identifiable {
    let id: String
    let relativePath: String
    let fileName: String
    let fileSize: Int64
    let contentModificationDate: Date
    /// Display/grouping date chosen by MediaDateSource priority.
    let derivedDate: Date?
    /// Where `derivedDate` came from; nil means Unknown Date.
    let dateSource: MediaDateSource?
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

    /// Kept as a compatibility accessor for callers that used the old name.
    var creationDate: Date? { derivedDate }

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

// The struct is an immutable value snapshot; all fields are value types.
extension MediaItem: @unchecked Sendable {}

extension MediaItem {
    /// A display title for the item.
    var displayName: String {
        fileName
    }

    /// A formatted creation date string for tooltips/overlays.
    var formattedDate: String? {
        guard let derivedDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: derivedDate)
    }

    /// Copy with an updated reverse-geocoded location name.
    func withLocationName(_ name: String) -> MediaItem {
        MediaItem(
            id: id,
            relativePath: relativePath,
            fileName: fileName,
            fileSize: fileSize,
            contentModificationDate: contentModificationDate,
            derivedDate: derivedDate,
            dateSource: dateSource,
            coordinate: coordinate,
            locationName: name,
            mediaType: mediaType,
            thumbnailPath: thumbnailPath
        )
    }
}

/// Stable key for grouping items that share a coordinate.
struct LocationKey: Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}
