import SwiftUI

/// "‹ All / 2022 / 2022-06" drill-down path. The chevron pops one level;
/// individual crumbs jump to that level.
struct TimeBreadcrumbView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        HStack(spacing: 6) {
            Button(action: viewModel.goBackOneLevel) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Go up one level")

            ForEach(Array(viewModel.breadcrumbItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Text("/")
                        .foregroundStyle(.secondary)
                }
                Button {
                    viewModel.focus(on: item.level)
                } label: {
                    Text(item.title)
                        .fontWeight(index == viewModel.breadcrumbItems.count - 1 ? .semibold : .regular)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}
