import Foundation

/// A point in the time hierarchy. Drill-down keeps this anchor while the
/// granularity changes; `nil` month/day means the whole parent range.
struct TimeAnchor: Equatable, Sendable {
    let year: Int
    let month: Int?
    let day: Int?

    init(year: Int, month: Int? = nil, day: Int? = nil) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parse section IDs produced by LibraryViewModel: `yyyy`, `yyyy-MM`,
    /// `yyyy-MM-dd`; "all" and "Unknown Date" return nil.
    init?(groupID: String) {
        let parts = groupID.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 || parts.count == 3,
              let year = Int(parts[0]),
              year > 0 else { return nil }
        let month = parts.count >= 2 ? Int(parts[1]) : nil
        let day = parts.count >= 3 ? Int(parts[2]) : nil
        if let month, !(1...12).contains(month) { return nil }
        if let day, !(1...31).contains(day) { return nil }
        self.init(year: year, month: month, day: day)
    }

    var monthTitle: String? {
        guard let month else { return nil }
        return String(format: "%04d-%02d", year, month)
    }
}

struct TimeBreadcrumbItem: Identifiable, Equatable {
    enum Level: Equatable {
        case all
        case year(Int)
        case month(Int, Int)
    }

    let level: Level
    let title: String

    var id: String { title }
}

/// Pure layout helper used by the grid's geometry reader and by tests with
/// simulated scroll positions.
enum TimeFocusResolver {
    /// The pinned/visible section whose top is at the viewport top. If no
    /// header is above the top (e.g. during a bounce), return the topmost one.
    static func topSection(
        frames: [String: CGFloat],
        viewportTop: CGFloat = 0,
        tolerance: CGFloat = 8
    ) -> String? {
        guard !frames.isEmpty else { return nil }
        let above = frames.filter { $0.value <= viewportTop + tolerance }
        if let best = above.max(by: { $0.value < $1.value }) {
            return best.key
        }
        return frames.min(by: { $0.value < $1.value })?.key
    }
}
