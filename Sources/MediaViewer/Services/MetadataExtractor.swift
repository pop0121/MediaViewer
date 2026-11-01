import AVFoundation
import CoreLocation
import Foundation
import ImageIO

struct ExtractedMetadata {
    let derivedDate: Date?
    let dateSource: MediaDateSource?
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
            let resolved = resolveDate(url: url, metadataDate: nil, metadataSource: .exif)
            return ExtractedMetadata(
                derivedDate: resolved.date,
                dateSource: resolved.source,
                coordinate: nil,
                mediaType: .photo
            )
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String: Any]

        let exifDate: Date? = {
            if let raw = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                return Self.exifDateFormatter.date(from: raw)
            }
            if let raw = exif?[kCGImagePropertyExifDateTimeDigitized as String] as? String {
                return Self.exifDateFormatter.date(from: raw)
            }
            return nil
        }()

        let coordinate = coordinate(fromGPS: properties?[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        let resolved = resolveDate(url: url, metadataDate: exifDate, metadataSource: .exif)
        return ExtractedMetadata(
            derivedDate: resolved.date,
            dateSource: resolved.source,
            coordinate: coordinate,
            mediaType: .photo
        )
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

        let coordinate: CLLocationCoordinate2D? = {
            let locationItems = AVMetadataItem.metadataItems(from: asset.commonMetadata,
                                                             filteredByIdentifier: .commonIdentifierLocation)
            if let locationString = locationItems.first?.stringValue {
                return Self.parseISO6709(locationString)
            }
            return nil
        }()

        let quickTimeDate: Date? = {
            let item = AVMetadataItem.metadataItems(
                from: asset.commonMetadata,
                filteredByIdentifier: .commonIdentifierCreationDate
            ).first
            return item?.dateValue
        }()
        let resolved = resolveDate(url: url, metadataDate: quickTimeDate, metadataSource: .quickTime)
        return ExtractedMetadata(
            derivedDate: resolved.date,
            dateSource: resolved.source,
            coordinate: coordinate,
            mediaType: .video
        )
    }

    /// Priority: EXIF/QuickTime > filename > fsModified (only when older than
    /// fsCreated) > fsCreated. This keeps copied files from claiming the copy
    /// date while preserving the real capture date whenever it is available.
    private func resolveDate(
        url: URL,
        metadataDate: Date?,
        metadataSource: MediaDateSource
    ) -> (date: Date?, source: MediaDateSource?) {
        if let metadataDate {
            return (metadataDate, metadataSource)
        }
        if let filenameDate = MediaDateParser.parse(fileName: url.lastPathComponent) {
            return (filenameDate, .filename)
        }
        return fallbackDate(for: url)
    }

    private func fallbackDate(for url: URL) -> (date: Date?, source: MediaDateSource?) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let modified = values?.contentModificationDate
        let created = values?.creationDate
        if let modified, let created {
            if modified < created {
                return (modified, .fsModified)
            }
            return (created, .fsCreated)
        }
        if let modified {
            return (modified, .fsModified)
        }
        if let created {
            return (created, .fsCreated)
        }
        return (nil, nil)
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
