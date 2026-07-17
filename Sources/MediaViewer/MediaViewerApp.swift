import SwiftUI

@main
struct MediaViewerApp: App {
    var body: some Scene {
        WindowGroup {
            GalleryView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Explicitly re-bind the standard app/window menu items. Running this SPM
            // executable target from the command line can leave the default Hide/Minimize
            // items inactive, so we replace them with direct NSApplication calls.
            CommandGroup(replacing: .appVisibility) {
                Button("Hide MediaViewer") {
                    NSApplication.shared.hide(nil)
                }
                .keyboardShortcut("h", modifiers: .command)

                Button("Hide Others") {
                    NSApplication.shared.hideOtherApplications(nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .option])

                Button("Show All") {
                    NSApplication.shared.unhideAllApplications(nil)
                }
            }

            CommandGroup(replacing: .windowSize) {
                Button("Minimize") {
                    NSApplication.shared.keyWindow?.miniaturize(nil)
                }
                .keyboardShortcut("m", modifiers: .command)

                Button("Zoom") {
                    NSApplication.shared.keyWindow?.zoom(nil)
                }
            }
        }
    }
}
