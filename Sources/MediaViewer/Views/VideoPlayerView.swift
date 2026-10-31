import AVKit
import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.showsSharingServiceButton = false
        // Show the whole frame at native aspect. The playback asset is the
        // original file; no thumbnail-sized layer is involved.
        playerView.videoGravity = .resizeAspect

        let player = AVPlayer(url: url)
        player.isMuted = true
        playerView.player = player

        context.coordinator.player = player
        context.coordinator.currentURL = url
        player.play()

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let coordinator = context.coordinator

        // SwiftUI reuses the NSView across item changes, so the player must be
        // repointed explicitly; otherwise the previous video keeps playing.
        if coordinator.currentURL != url {
            coordinator.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
            coordinator.currentURL = url
        }

        guard let player = nsView.player else { return }
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.player?.pause()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPlaying: $isPlaying)
    }

    class Coordinator {
        @Binding var isPlaying: Bool
        var player: AVPlayer?
        var currentURL: URL?

        init(isPlaying: Binding<Bool>) {
            self._isPlaying = isPlaying
        }

        deinit {
            player?.pause()
        }
    }
}
