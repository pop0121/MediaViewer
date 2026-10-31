import Foundation

/// Reads the persisted grid density and migrates the pre-preset `zoomLevel`
/// default (which allowed 0.3...2.0) into the new 0.5...2.0 range.
enum DensityPreferences {
    static let key = "gridDensity"
    static let legacyKey = "zoomLevel"

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0.5), 2.0)
    }

    static func storedValue(in defaults: UserDefaults = .standard) -> Double? {
        let raw = (defaults.object(forKey: key) as? Double)
            ?? (defaults.object(forKey: legacyKey) as? Double)
        return raw.map(clamp)
    }
}
