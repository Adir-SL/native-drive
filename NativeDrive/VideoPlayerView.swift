import AVKit
import SwiftUI

struct VideoPlayerView: View {
    @ObservedObject var session: MediaSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = session.player {
                PlayerContainer(player: player, session: session)
                if session.isAudio {
                    Image(systemName: "waveform")
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.85))
                        .allowsHitTesting(false)
                }
            } else {
                VStack(spacing: 16) {
                    if session.playbackFailed || session.kind == .unsupported {
                        Image(systemName: "play.slash")
                            .font(.system(size: 42))
                            .foregroundStyle(.white.opacity(0.8))
                        MediaStatusBanner(session: session)
                        Button("Open in default app") {
                            session.openInDefaultApp()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else if let fraction = session.downloadFraction {
                        ProgressView(value: fraction)
                            .frame(width: 220)
                            .tint(.white)
                        Text("Downloading \(session.fileName)")
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Opening \(session.fileName)")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(24)
            }
            VStack {
                HStack(spacing: 12) {
                    Button { session.dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                    Text(session.fileName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(.black.opacity(0.45))
                .buttonStyle(.borderless)
                Spacer()
            }
        }
        .onExitCommand { session.dismiss() }
    }
}

private struct PlayerContainer: NSViewRepresentable {
    let player: AVPlayer
    let session: MediaSession

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = player
        session.playerView = view
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        session.playerView = view
    }
}
