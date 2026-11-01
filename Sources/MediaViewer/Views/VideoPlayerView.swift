import AVKit
import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    @Binding var isPlaying: Bool
    let enhancementEnabled: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.showsSharingServiceButton = false
        // Show the whole frame at native aspect. The playback asset is the
        // original file; no thumbnail-sized layer is involved.
        playerView.videoGravity = .resizeAspect

        let player = AVPlayer()
        // Audio is part of the media: keep the player unmuted. Batch 8
        // diagnosed the "no sound" report to this line.
        player.isMuted = false
        playerView.player = player

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        context.coordinator.player = player
        context.coordinator.configure(item: item, url: url, enhancementEnabled: enhancementEnabled)
        // Do not call play() here. SwiftUI calls updateNSView immediately after
        // makeNSView; starting playback before the view is installed races the
        // AVPlayerController KVO setup and crashes when a finished video is
        // followed by another video (macOS 14, custom videoComposition path).

        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let coordinator = context.coordinator

        // SwiftUI reuses the NSView across item changes, so the player must be
        // repointed explicitly; otherwise the previous video keeps playing.
        if coordinator.currentURL != url {
            // Drop the previous item explicitly. Replacing an ended item that
            // still carries a custom videoComposition can over-release its
            // AVURLAsset during deallocation on macOS 14 (crash observed when
            // switching from a finished video in the enhancement path).
            coordinator.prepareForReplacement()
            let item = AVPlayerItem(url: url)
            coordinator.configure(item: item, url: url, enhancementEnabled: enhancementEnabled)
            coordinator.player?.replaceCurrentItem(with: item)
            coordinator.currentURL = url
        } else if coordinator.appliedEnhancement != enhancementEnabled {
            // Changing videoComposition does not replace the item, so the
            // current playback time and the player's play/pause state survive.
            coordinator.applyEnhancement(enhancementEnabled, url: url)
        }

        guard let player = nsView.player else { return }
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.prepareForReplacement()
        // AVPlayerView keeps KVO/MediaRemote observers tied to its player. If
        // the view is discarded (for example when the viewer switches to a
        // photo), drop both sides explicitly before deallocation.
        nsView.player = nil
        coordinator.player = nil
        coordinator.currentItem = nil
        coordinator.currentURL = nil
        coordinator.appliedEnhancement = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isPlaying: $isPlaying)
    }

    class Coordinator {
        @Binding var isPlaying: Bool
        var player: AVPlayer?
        var currentURL: URL?
        var currentItem: AVPlayerItem?
        var appliedEnhancement: Bool?

        init(isPlaying: Binding<Bool>) {
            self._isPlaying = isPlaying
        }

        func configure(item: AVPlayerItem, url: URL, enhancementEnabled: Bool) {
            currentItem = item
            currentURL = url
            applyEnhancement(enhancementEnabled, url: url)
        }

        /// Clear the custom composition before AVPlayer replaces/releases the
        /// ended item. Releasing an item with a live custom composition crashes
        /// inside AVURLAsset deallocation on macOS 14.
        func prepareForReplacement() {
            player?.pause()
            currentItem?.videoComposition = nil
        }

        func applyEnhancement(_ enabled: Bool, url: URL) {
            guard let item = currentItem else { return }
            // Assigning a custom videoComposition rewinds the item to zero on
            // macOS. Preserve the playhead and rate so the toggle is a seek,
            // not a restart. The seek is the only visible cost of switching.
            let time = player?.currentTime() ?? .zero
            let wasPlaying = (player?.rate ?? 0) > 0
            if enabled {
                item.videoComposition = VideoEnhancementCompositionFactory.make(
                    for: url,
                    chain: VideoEnhancementSettings.chain
                )
            } else {
                // Off is exactly the batch-5 path: no custom compositor.
                item.videoComposition = nil
            }
            if time.seconds > 0 {
                player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if wasPlaying { player?.play() }
            appliedEnhancement = enabled
        }

        deinit {
            player?.pause()
        }
    }
}
