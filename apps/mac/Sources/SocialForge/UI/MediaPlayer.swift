import AVKit
import AppKit
import SwiftUI

/// Plays a video or audio file in place with the system controls.
///
/// AppKit's AVPlayerView, not SwiftUI's VideoPlayer: VideoPlayer's AVKit overlay
/// crashed the app while loading (type metadata in _AVKit_SwiftUI) when a ComfyUI
/// music result was selected. The player pauses when the view goes away.
struct MediaPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url
        if current != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
