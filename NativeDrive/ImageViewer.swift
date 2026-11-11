import AppKit
import SwiftUI

struct ImageViewer: View {
    @ObservedObject var session: MediaSession

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geometry in
                ZStack {
                    if let image = session.fullImage ?? session.thumbnail {
                        ZoomableImage(image: image)
                            .id(session.fileID)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            VStack(spacing: 0) {
                header
                Spacer()
                if session.message != nil {
                    MediaStatusBanner(session: session)
                        .padding(.bottom, 20)
                }
            }
        }
        .onExitCommand { session.dismiss() }
    }

    private var header: some View {
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
            Button { session.step(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!session.canGoBack)
            Text(session.positionLabel)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 72)
            Button { session.step(1) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!session.canGoForward)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(.black.opacity(0.45))
        .buttonStyle(.borderless)
    }
}

struct MediaStatusBanner: View {
    @ObservedObject var session: MediaSession
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = session.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
            }
            if let detail = session.detail, !detail.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Details")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            if session.canRetry {
                Button("Retry") { session.retry() }
            }
        }
        .padding(12)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}

private struct ZoomableImage: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .scaleEffect(zoom)
            .offset(pan)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ImageInteractionView(
                    onZoom: { factor in
                        let next = min(max(zoom * factor, 1), 8)
                        zoom = next
                        if next <= 1.001 {
                            zoom = 1
                            pan = .zero
                        }
                    },
                    onPan: { delta in
                        guard zoom > 1 else { return }
                        pan.width += delta.width
                        pan.height += delta.height
                    },
                    onReset: {
                        zoom = 1
                        pan = .zero
                    }
                )
            }
            .animation(.easeOut(duration: 0.12), value: zoom == 1)
    }
}

private struct ImageInteractionView: NSViewRepresentable {
    var onZoom: @MainActor (CGFloat) -> Void
    var onPan: @MainActor (CGSize) -> Void
    var onReset: @MainActor () -> Void

    func makeNSView(context: Context) -> InteractionNSView {
        let view = InteractionNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: InteractionNSView, context: Context) {
        context.coordinator.onZoom = onZoom
        context.coordinator.onPan = onPan
        context.coordinator.onReset = onReset
        nsView.coordinator = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoom: onZoom, onPan: onPan, onReset: onReset)
    }

    @MainActor
    final class Coordinator {
        var onZoom: @MainActor (CGFloat) -> Void
        var onPan: @MainActor (CGSize) -> Void
        var onReset: @MainActor () -> Void

        init(
            onZoom: @escaping @MainActor (CGFloat) -> Void,
            onPan: @escaping @MainActor (CGSize) -> Void,
            onReset: @escaping @MainActor () -> Void
        ) {
            self.onZoom = onZoom
            self.onPan = onPan
            self.onReset = onReset
        }
    }

    final class InteractionNSView: NSView {
        weak var coordinator: Coordinator?
        private var lastDrag: NSPoint = .zero

        override var acceptsFirstResponder: Bool { true }

        override func magnify(with event: NSEvent) {
            let factor = 1 + event.magnification
            MainActor.assumeIsolated {
                self.coordinator?.onZoom(factor)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 8
            guard delta != 0 else { return }
            let factor = 1 + delta * 0.012
            MainActor.assumeIsolated {
                self.coordinator?.onZoom(factor)
            }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                MainActor.assumeIsolated {
                    self.coordinator?.onReset()
                }
                return
            }
            lastDrag = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            let point = event.locationInWindow
            let delta = CGSize(width: point.x - lastDrag.x, height: lastDrag.y - point.y)
            lastDrag = point
            MainActor.assumeIsolated {
                self.coordinator?.onPan(delta)
            }
        }
    }
}
