import SwiftUI

/// Reports each section header's vertical position in the grid scroll view.
struct SectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SectionFrameReader: View {
    let id: String
    let coordinateSpace: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SectionFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(coordinateSpace)).minY]
            )
        }
    }
}
