import CoreData
import CoreLocation
import Foundation

@objc(MediaItemEntity)
final class MediaItemEntity: NSManagedObject {
    @NSManaged var relativePath: String
    @NSManaged var fileName: String
    @NSManaged var fileSize: Int64
    @NSManaged var contentModificationDate: Date
    /// Legacy column kept for lightweight migration; new code uses derivedDate.
    @NSManaged var creationDate: Date?
    @NSManaged var derivedDate: Date?
    @NSManaged var dateSourceRaw: String?
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var locationName: String?
    @NSManaged var mediaTypeRaw: String
    @NSManaged var thumbnailPath: String?
    /// JSON-encoded album names imported from vivo 办公套件; nil/empty = none.
    @NSManaged var albumNamesRaw: String?

    /// Stored (vivo-imported) album names, decoded. Folder albums are derived
    /// from relativePath by the UI layer and never stored here.
    var storedAlbumNames: [String] {
        get {
            guard let albumNamesRaw,
                  let data = albumNamesRaw.data(using: .utf8),
                  let names = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return names
        }
        set {
            guard !newValue.isEmpty else {
                albumNamesRaw = nil
                return
            }
            albumNamesRaw = try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)
        }
    }

    var dateSource: MediaDateSource? {
        get { dateSourceRaw.flatMap(MediaDateSource.init(rawValue:)) }
        set { dateSourceRaw = newValue?.rawValue }
    }

    var mediaType: MediaItem.MediaType {
        get { MediaItem.MediaType(rawValue: mediaTypeRaw) ?? .photo }
        set { mediaTypeRaw = newValue.rawValue }
    }

    var coordinate: CLLocationCoordinate2D? {
        get {
            // Use an impossible sentinel to mean "no coordinate".
            if latitude == 0 && longitude == 0 { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        set {
            if let newValue {
                latitude = newValue.latitude
                longitude = newValue.longitude
            } else {
                latitude = 0
                longitude = 0
            }
        }
    }
}

extension MediaItem {
    /// Lightweight snapshot of an indexed entity for the UI layer.
    init(entity: MediaItemEntity) {
        self.init(
            id: entity.relativePath,
            relativePath: entity.relativePath,
            fileName: entity.fileName,
            fileSize: entity.fileSize,
            contentModificationDate: entity.contentModificationDate,
            derivedDate: entity.derivedDate ?? entity.creationDate,
            dateSource: entity.dateSource,
            coordinate: entity.coordinate,
            locationName: entity.locationName,
            mediaType: entity.mediaType,
            thumbnailPath: entity.thumbnailPath,
            albumNames: Self.combiningAlbums(folder: Self.folderAlbumName(relativePath: entity.relativePath),
                                             stored: entity.storedAlbumNames)
        )
    }
}

@objc(LocationNameEntity)
final class LocationNameEntity: NSManagedObject {
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var name: String
}
