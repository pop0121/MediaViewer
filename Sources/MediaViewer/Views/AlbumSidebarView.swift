import AppKit
import SwiftUI

/// Sidebar album filter. "所有媒体" clears the filter; selecting an album
/// scopes the grid/map to that album while the date/location grouping keeps
/// working inside it.
struct AlbumSidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel

    /// Empty string is the "all media" sentinel; real albums are never empty.
    private var selection: Binding<String> {
        Binding(
            get: { viewModel.selectedAlbum ?? "" },
            set: { viewModel.selectedAlbum = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section("相册") {
                Label("所有媒体", systemImage: "photo.stack")
                    .badge(viewModel.items.count)
                    .tag("")
                if viewModel.albumSummaries.isEmpty {
                    Text("尚无相册")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.albumSummaries, id: \.name) { album in
                        Label(album.name, systemImage: "folder")
                            .badge(album.count)
                            .tag(album.name)
                            .help(album.name)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let notice = viewModel.vivoAlbumNotice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if viewModel.vivoAlbumAccessDenied {
                    Button("授权访问 vivo 数据…") {
                        grantPcsuiteAccess()
                    }
                    .controlSize(.small)
                }
                Button {
                    Task { await viewModel.importVivoAlbums() }
                } label: {
                    Label("从 vivo 办公套件导入相册", systemImage: "arrow.down.doc")
                }
                .controlSize(.small)
                .disabled(viewModel.isScanning)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationTitle("MediaViewer")
    }

    /// Sandboxed builds cannot read another app's data without an explicit
    /// user grant. Ask for TransferRecord.db and persist a scoped bookmark.
    private func grantPcsuiteAccess() {
        let panel = NSOpenPanel()
        panel.title = "选择 vivo 办公套件的 TransferRecord.db"
        panel.message = "位于 ~/Library/Application Support/pcsuite/database/"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pcsuite/database")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try VivoAlbumImporter.storeBookmark(for: url)
            } catch {
                Log.library.error("Failed to store pcsuite bookmark: \(error.localizedDescription, privacy: .public)")
                return
            }
            Task { await viewModel.importVivoAlbums() }
        }
    }
}
