import AppKit
import SwiftUI

struct KeyMonitor: NSViewRepresentable {
    var onEvent: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            context.coordinator.onEvent(event) ? nil : event
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

    final class Coordinator {
        var onEvent: (NSEvent) -> Bool
        var monitor: Any?
        init(onEvent: @escaping (NSEvent) -> Bool) {
            self.onEvent = onEvent
        }
    }
}

enum KeyRouting {
    static func handle(_ event: NSEvent, browser: BrowserModel?) -> Bool {
        guard let browser else { return false }
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
        return false
    }
}
