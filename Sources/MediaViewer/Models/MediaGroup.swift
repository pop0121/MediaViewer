import Foundation

struct MediaGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [MediaItem]
    var isCollapsed: Bool = false

    var count: Int { items.count }
}

enum GroupingMode: String, CaseIterable, Identifiable {
    case all
    case years
    case months
    case days
    case location

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: return "All"
        case .years: return "Years"
        case .months: return "Months"
        case .days: return "Days"
        case .location: return "Places"
        }
    }

    var isMap: Bool { self == .location }
}
