import Foundation

/// Parse capture times embedded in common camera / WeChat / screenshot names.
/// This is deliberately independent of ImageIO and filesystem metadata so the
/// rules can be unit-tested and so a copied file's creation date does not win
/// over a date written by the app that produced it.
enum MediaDateParser {
    private static let oldestAllowed = DateComponents(year: 1990, month: 1, day: 1)

    /// Returns the parsed date, or nil when the name has no trustworthy date.
    static func parse(
        fileName: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        let name = (fileName as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }

        // mmexport<epoch> and mmexport_<epoch>: the 13-digit form must be
        // tried before the 10-digit form so we do not truncate milliseconds.
        let epochPatterns: [(String, Int)] = [
            (#"(?i)(?:^|[_\-\s])?mmexport[_\-\s]?(\d{13})(?!\d)"#, 13),
            (#"(?i)(?:^|[_\-\s])?mmexport[_\-\s]?(\d{10})(?!\d)"#, 10),
            (#"(?i)image[_\-\s]?editor[_\-\s]?(\d{13})(?!\d)"#, 13),
            (#"^(\d{13})$"#, 13)
        ]
        for (pattern, digits) in epochPatterns {
            if let match = firstMatch(pattern, in: stem),
               let epoch = Int(match) {
                return epochDate(epoch, digits: digits, now: now, calendar: calendar)
            }
        }

        // Screenshot / camera / scanner / WeChat names:
        // Screenshot_yyyyMMdd_HHmmss, IMG_yyyyMMdd_HHmmss,
        // 扫描文件_yyyyMMdd_HHmmss, 微信图片_yyyyMMddHHmmss.
        let datePattern = #"(?i)(?:screenshot|img|扫描文件|微信图片)[_\-\s]?(20\d{2})(\d{2})(\d{2})[_\-\s]?(\d{2})(\d{2})(\d{2})"#
        if let match = firstMatch(datePattern, in: stem) {
            // The regex has six capture groups; firstMatch returns only the
            // first. Re-run to get all components via NSRegularExpression.
            if let comps = components(from: datePattern, in: stem) {
                return date(
                    year: comps.0, month: comps.1, day: comps.2,
                    hour: comps.3, minute: comps.4, second: comps.5,
                    now: now, calendar: calendar
                )
            }
            _ = match
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range),
              result.numberOfRanges > 1,
              let matchRange = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[matchRange])
    }

    private static func components(
        from pattern: String,
        in text: String
    ) -> (Int, Int, Int, Int, Int, Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range),
              result.numberOfRanges >= 7 else { return nil }
        var values: [Int] = []
        for index in 1...6 {
            guard let componentRange = Range(result.range(at: index), in: text),
                  let value = Int(text[componentRange]) else { return nil }
            values.append(value)
        }
        return (values[0], values[1], values[2], values[3], values[4], values[5])
    }

    private static func epochDate(
        _ epoch: Int,
        digits: Int,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let seconds: TimeInterval
        if digits == 13 {
            seconds = TimeInterval(epoch) / 1000.0
        } else {
            seconds = TimeInterval(epoch)
        }
        let date = Date(timeIntervalSince1970: seconds)
        guard date <= now.addingTimeInterval(86_400),
              let oldest = calendar.date(from: oldestAllowed),
              date >= oldest else { return nil }
        return date
    }

    private static func date(
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int, second: Int,
        now: Date, calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components),
              let check = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
              ) as DateComponents?,
              check.year == year, check.month == month, check.day == day,
              check.hour == hour, check.minute == minute, check.second == second,
              date <= now.addingTimeInterval(86_400),
              let oldest = calendar.date(from: oldestAllowed),
              date >= oldest else { return nil }
        return date
    }
}
