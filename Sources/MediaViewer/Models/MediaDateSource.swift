import Foundation

/// Where the display date came from, ordered by confidence.
enum MediaDateSource: String, CaseIterable, Sendable {
    case exif
    case quickTime
    case filename
    case fsModified
    case fsCreated

    var displayName: String {
        switch self {
        case .exif: return "EXIF"
        case .quickTime: return "QuickTime"
        case .filename: return "文件名"
        case .fsModified: return "文件修改时间"
        case .fsCreated: return "文件创建时间"
        }
    }

    var shortDescription: String {
        "时间来自\(displayName)"
    }
}
