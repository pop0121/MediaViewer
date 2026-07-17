import Foundation

struct MediaGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [MediaItem]
    var isCollapsed: Bool = false

    var count: Int { items.count }
}

enum GroupingMode: String, CaseIterable, Identifiable {
    case none
    case date
    case location

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .date: return "Date"
        case .location: return "Location"
        }
    }
}
