import AVFoundation
import CoreLocation
import Foundation
import ImageIO

struct ExtractedMetadata {
    let creationDate: Date?
    let coordinate: CLLocationCoordinate2D?
    let mediaType: MediaItem.MediaType
}

final class MetadataExtractor {
    func extract(from url: URL) -> ExtractedMetadata {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov"].contains(ext) {
            return extractVideoMetadata(from: url)
        } else {
            return extractPhotoMetadata(from: url)
        }
    }

    // MARK: - Photos

    private func extractPhotoMetadata(from url: URL) -> ExtractedMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return ExtractedMetadata(creationDate: nil, coordinate: nil, mediaType: .photo)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]

        let creationDate: Date? = {
            if let raw = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                return Self.exifDateFormatter.date(from: raw)
            }
            if let raw = exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String {
                return Self.exifDateFormatter.date(from: raw)
            }
            return fileCreationDate(url: url)
        }()

        let coordinate = coordinate(fromGPS: properties?[kCGImagePropertyGPSDictionary as String] as? [String: Any])

        return ExtractedMetadata(creationDate: creationDate, coordinate: coordinate, mediaType: .photo)
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private func coordinate(fromGPS gps: [String: Any]?) -> CLLocationCoordinate2D? {
        guard let gps else { return nil }
        guard let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double else {
            return nil
        }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String
        let lat = latRef?.uppercased() == "S" ? -latitude : latitude
        let lon = lonRef?.uppercased() == "W" ? -longitude : longitude
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Videos

    private func extractVideoMetadata(from url: URL) -> ExtractedMetadata {
        let asset = AVAsset(url: url)

        var creationDate: Date? = fileCreationDate(url: url)
        var coordinate: CLLocationCoordinate2D? = nil

        let creationDateItem = AVMetadataItem.metadataItems(from: asset.commonMetadata,
                                                            filteredByIdentifier: .commonIdentifierCreationDate).first
        if let dateValue = creationDateItem?.dateValue {
            creationDate = dateValue
        }

        let locationItems = AVMetadataItem.metadataItems(from: asset.commonMetadata,
                                                         filteredByIdentifier: .commonIdentifierLocation)
        if let locationString = locationItems.first?.stringValue {
            coordinate = Self.parseISO6709(locationString)
        }

        return ExtractedMetadata(creationDate: creationDate, coordinate: coordinate, mediaType: .video)
    }

    private func fileCreationDate(url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate
    }

    /// Parse an ISO 6709 location string such as "+35.6814+139.7671/".
    private static func parseISO6709(_ string: String) -> CLLocationCoordinate2D? {
        var trimmed = string
        if trimmed.hasSuffix("/") { trimmed.removeLast() }

        let pattern = #"[+-]?\d+\.?\d*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let matches = regex.matches(in: trimmed, options: [], range: range)

        guard matches.count >= 2 else { return nil }
        let latRange = Range(matches[0].range, in: trimmed)
        let lonRange = Range(matches[1].range, in: trimmed)
        guard let latString = latRange.map({ String(trimmed[$0]) }),
              let lonString = lonRange.map({ String(trimmed[$0]) }),
              let lat = Double(latString),
              let lon = Double(lonString) else {
            return nil
        }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
