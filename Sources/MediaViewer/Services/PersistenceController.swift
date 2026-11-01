import CoreData
import Foundation

final class PersistenceController {
    static let modelName = "MediaViewer"

    let container: NSPersistentContainer

    init(storeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        container = NSPersistentContainer(name: PersistenceController.modelName,
                                          managedObjectModel: PersistenceController.makeModel())
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in
            loadError = error
        }
        if let loadError {
            let nsError = loadError as NSError
            Log.scan.error(
                "Core Data store open failed path=\(storeURL.path, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) underlying=\(String(describing: nsError.userInfo[NSUnderlyingErrorKey]), privacy: .public)"
            )
            throw loadError
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Build the Core Data model in code so we do not depend on a bundled .xcdatamodeld.
    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // MediaItemEntity
        let itemEntity = NSEntityDescription()
        itemEntity.name = "MediaItemEntity"
        itemEntity.managedObjectClassName = "MediaItemEntity"

        let relativePath = NSAttributeDescription()
        relativePath.name = "relativePath"
        relativePath.attributeType = .stringAttributeType
        relativePath.isOptional = false

        let fileName = NSAttributeDescription()
        fileName.name = "fileName"
        fileName.attributeType = .stringAttributeType
        fileName.isOptional = false

        let fileSize = NSAttributeDescription()
        fileSize.name = "fileSize"
        fileSize.attributeType = .integer64AttributeType
        fileSize.isOptional = false

        let contentModificationDate = NSAttributeDescription()
        contentModificationDate.name = "contentModificationDate"
        contentModificationDate.attributeType = .dateAttributeType
        contentModificationDate.isOptional = false

        let creationDate = NSAttributeDescription()
        creationDate.name = "creationDate"
        creationDate.attributeType = .dateAttributeType
        creationDate.isOptional = true

        let derivedDate = NSAttributeDescription()
        derivedDate.name = "derivedDate"
        derivedDate.attributeType = .dateAttributeType
        derivedDate.isOptional = true

        let dateSourceRaw = NSAttributeDescription()
        dateSourceRaw.name = "dateSourceRaw"
        dateSourceRaw.attributeType = .stringAttributeType
        dateSourceRaw.isOptional = true

        let latitude = NSAttributeDescription()
        latitude.name = "latitude"
        latitude.attributeType = .doubleAttributeType
        latitude.isOptional = false
        latitude.defaultValue = 0.0

        let longitude = NSAttributeDescription()
        longitude.name = "longitude"
        longitude.attributeType = .doubleAttributeType
        longitude.isOptional = false
        longitude.defaultValue = 0.0

        let locationName = NSAttributeDescription()
        locationName.name = "locationName"
        locationName.attributeType = .stringAttributeType
        locationName.isOptional = true

        let mediaTypeRaw = NSAttributeDescription()
        mediaTypeRaw.name = "mediaTypeRaw"
        mediaTypeRaw.attributeType = .stringAttributeType
        mediaTypeRaw.isOptional = false

        let thumbnailPath = NSAttributeDescription()
        thumbnailPath.name = "thumbnailPath"
        thumbnailPath.attributeType = .stringAttributeType
        thumbnailPath.isOptional = true

        itemEntity.properties = [
            relativePath, fileName, fileSize, contentModificationDate,
            creationDate, derivedDate, dateSourceRaw, latitude, longitude, locationName,
            mediaTypeRaw, thumbnailPath
        ]
        itemEntity.uniquenessConstraints = [[relativePath]]

        // LocationNameEntity
        let locationEntity = NSEntityDescription()
        locationEntity.name = "LocationNameEntity"
        locationEntity.managedObjectClassName = "LocationNameEntity"

        let locLat = NSAttributeDescription()
        locLat.name = "latitude"
        locLat.attributeType = .doubleAttributeType
        locLat.isOptional = false

        let locLon = NSAttributeDescription()
        locLon.name = "longitude"
        locLon.attributeType = .doubleAttributeType
        locLon.isOptional = false

        let locName = NSAttributeDescription()
        locName.name = "name"
        locName.attributeType = .stringAttributeType
        locName.isOptional = false

        locationEntity.properties = [locLat, locLon, locName]
        locationEntity.uniquenessConstraints = [["latitude", "longitude"]]

        model.entities = [itemEntity, locationEntity]
        return model
    }

    /// New SQLite URL in Application Support. The legacy `.mediaviewer`
    /// directory is intentionally not used for new writes.
    static func storeURL(for rootURL: URL) -> URL {
        MediaStorageLocations(rootURL: rootURL).storeURL
    }

    static func thumbnailsDirectory(for rootURL: URL) -> URL {
        MediaStorageLocations(rootURL: rootURL).thumbnailsDirectory
    }
}
