import AppKit
import SwiftUI

@MainActor
struct KeyMonitor: NSViewRepresentable {
    var onEvent: @MainActor (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors are delivered on the main thread. assumeIsolated keeps
            // the consume/pass decision synchronous so the key is not also typed.
            let handled = MainActor.assumeIsolated {
                coordinator.onEvent(event)
            }
            return handled ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    @MainActor
    final class Coordinator {
        var onEvent: @MainActor (NSEvent) -> Bool
        var monitor: Any?

        init(onEvent: @escaping @MainActor (NSEvent) -> Bool) {
            self.onEvent = onEvent
        }
    }
}

@MainActor
enum KeyRouting {
    static func handle(_ event: NSEvent, browser: BrowserModel?) -> Bool {
        guard let browser else { return false }
        if browser.mediaSession != nil {
            return browser.mediaSession?.handleKey(event) ?? false
        }
        if browser.renamingID != nil { return false }
        guard let window = event.window, window.isKeyWindow, !window.isSheet else { return false }
        if window.firstResponder is NSTextView { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) {
            browser.openSelection()
            return true
        }
        if flags == .command && event.keyCode == 125 {
            browser.openSelection()
            return true
        }
        if flags.isEmpty && event.keyCode == 49 {
            browser.quickLookSelection()
            return true
        }
        if flags == [.command, .shift] && event.keyCode == 45 {
            browser.makeNew(.folder)
            return true
        }
        if flags == [.command, .shift] && event.keyCode == 1 {
            browser.shareSelection()
            return true
        }
        return false
    }
}
