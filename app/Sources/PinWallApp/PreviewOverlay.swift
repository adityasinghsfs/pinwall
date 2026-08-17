import SwiftUI
import AppKit

/// In-app, full-screen "fake screensaver" preview.
///
/// Unlike the real screensaver this never engages the system saver and never
/// locks the Mac — it's just a borderless black window covering the screen,
/// showing the live wall with an "Esc to exit" hint that fades out. Pressing
/// Esc closes it and drops you straight back to the PinWall app and desktop.
@MainActor
final class PreviewController {
    static let shared = PreviewController()
    private var window: NSWindow?
    private var keyMonitor: Any?

    func show() {
        if window != nil { return }   // already showing

        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let win = PreviewWindow(contentRect: frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.level = .screenSaver                       // cover dock + menu bar like a real saver
        win.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle]
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.contentView = NSHostingView(
            rootView: PreviewScreensaverView(onExit: { [weak self] in self?.close() })
        )
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win

        // Esc closes the preview. Local monitor is enough — the window is key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }   // 53 = Esc
            return e
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        window?.orderOut(nil)
        window = nil
    }
}

/// A borderless window can't become key by default, but we need key focus to
/// catch the Esc keystroke.
final class PreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The preview's content: the live wall behind a top hint that fades away.
private struct PreviewScreensaverView: View {
    let onExit: () -> Void
    @State private var settings = WallSettings.load()
    @State private var hintOpacity: Double = 1

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            // gallery:false → the live, animated wall (entrance plays on load)
            WallWebView(gallery: false, settings: settings)

            hint
                .padding(.top, 40)
                .opacity(hintOpacity)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onAppear {
            // Show the hint, then fade it out after a couple of seconds.
            withAnimation(.easeOut(duration: 1.2).delay(2.5)) { hintOpacity = 0 }
        }
    }

    private var hint: some View {
        VStack(spacing: 3) {
            Text("Press Esc to exit preview")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text("this is only a preview — your screen won’t lock")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 20)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .environment(\.colorScheme, .dark)
    }
}
