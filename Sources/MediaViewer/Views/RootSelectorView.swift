import SwiftUI

struct RootSelectorView: View {
    @Binding var rootURL: URL?
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("Welcome to MediaViewer")
                .font(.title)

            Text("Choose a folder containing your photos and videos.")
                .foregroundStyle(.secondary)

            Button("Choose Folder…") {
                pickFolder()
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(minWidth: 400, minHeight: 300)
        .padding()
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the root folder for your media library"

        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            rootURL = url
            onSelect(url)
        }
    }
}
