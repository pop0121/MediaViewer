import SwiftUI

/// Breadcrumb for a cluster-scoped grid: "‹ Map    500 photos".
struct ClusterBreadcrumbView: View {
    let label: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("Map", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Back to map")

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}
