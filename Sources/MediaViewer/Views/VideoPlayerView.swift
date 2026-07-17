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

        let player = AVPlayer(url: url)
        player.isMuted = true
        playerView.player = player

        context.coordinator.player = player
        player.play()
        isPlaying = true

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        guard let player = nsView.player else { return }
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPlaying: $isPlaying)
    }

    class Coordinator {
        @Binding var isPlaying: Bool
        var player: AVPlayer?

        init(isPlaying: Binding<Bool>) {
            self._isPlaying = isPlaying
        }

        deinit {
            player?.pause()
        }
    }
}
