import Foundation
import os

/// Central loggers. Never use `print` for diagnostics.
enum Log {
    static let subsystem = "com.example.MediaViewer"
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let library = Logger(subsystem: subsystem, category: "library")
    static let thumbnails = Logger(subsystem: subsystem, category: "thumbnails")
    static let geocode = Logger(subsystem: subsystem, category: "geocode")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")
    static let collapse = Logger(subsystem: subsystem, category: "collapse")
}

/// Timed intervals. Signposts are always emitted for Instruments; human-readable
/// timings are only logged when `MEDIAVIEWER_TIMING=1` is set in the environment.
enum Perf {
    static let enabled = ProcessInfo.processInfo.environment["MEDIAVIEWER_TIMING"] == "1"

    private static let logger = Logger(subsystem: Log.subsystem, category: "perf")
    private static let signposter = OSSignposter(subsystem: Log.subsystem, category: "perf")

    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let start: CFAbsoluteTime
    }

    static func begin(_ name: StaticString) -> Interval {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        return Interval(name: name, state: state, start: CFAbsoluteTimeGetCurrent())
    }

    static func end(_ interval: Interval, _ detail: String = "") {
        signposter.endInterval(interval.name, interval.state)
        guard enabled else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - interval.start) * 1000
        logger.notice("\(interval.name, privacy: .public): \(elapsed, format: .fixed(precision: 1)) ms \(detail, privacy: .public)")
    }
}
