import SwiftUI
import AppKit

// Custom entry point so `PinWall.app --harvest` can run headless (no window,
// no dock icon) and exit, while a normal launch shows the SwiftUI UI.
@main
enum PinWallMain {
    static func main() {
        if CommandLine.arguments.contains("--harvest") {
            Harvester.runHeadlessAndExit()   // does not return
        }
        PinWallGUI.main()
    }
}

struct PinWallGUI: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PinWall") {
            RootView()
                .frame(minWidth: 940, minHeight: 620)
                .background(Color.black)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 720)

        Window("PinWall Gallery", id: "gallery") {
            GalleryView()
                .frame(minWidth: 760, minHeight: 520)
                .background(Color.black)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Check GitHub for a newer release shortly after launch (Phase 4).
        Updater.shared.checkOnLaunch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
