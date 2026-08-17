import SwiftUI
import AppKit
import Security

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

        // App Translocation: macOS runs quarantined apps from a read-only,
        // disappearing path. The screensaver mirror + harvest agent can't be
        // wired to it, so warn the user to move PinWall to /Applications.
        if PinWall.isTranslocated {
            warnTranslocated()
            return   // don't write ephemeral paths anywhere
        }

        // Record our path so the screensaver's "Configure" button can open us.
        UserDefaults(suiteName: PinWall.suiteName)?.set(Bundle.main.bundlePath, forKey: "appPath")
        // One-time migration: pre-cache installs kept the whole feed in pins.json
        // (always Pinterest). Seed the pinterest cache from it so the first tab
        // switch doesn't lose the wall. saveCache ignores empty writes.
        let s0 = WallSettings.load()
        if s0.provider == "pinterest", PinStore.loadCache(for: "pinterest").isEmpty {
            PinStore.saveCache(PinStore.load(), for: "pinterest")
        }
        // Keep the installed screensaver in sync with THIS app version, so a
        // saver bugfix ships with an app update.
        Installer.syncSaverIfNeeded()
        // Publish the wall as plain files for the sandboxed screensaver.
        PinWall.publishSaverMirror()
        // Self-heal the harvest LaunchAgent: re-point it at THIS binary.
        if WallSettings.load().connected {
            if !Installer.installHarvestAgent() {
                UserDefaults(suiteName: PinWall.suiteName)?.set(true, forKey: "agentInstallFailed")
            } else {
                UserDefaults(suiteName: PinWall.suiteName)?.set(false, forKey: "agentInstallFailed")
            }
        }
        // Updates are user-driven: no launch-time prompt. The settings panel's
        // "Check for updates" button is the only trigger, so an update never
        // interrupts on launch.
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func warnTranslocated() {
        let a = NSAlert()
        a.messageText = "Move PinWall to Applications"
        a.informativeText = "PinWall is running from a temporary, read-only location, so the "
            + "screensaver and hourly refresh can't be set up. Drag PinWall into your Applications "
            + "folder, then open it from there."
        a.addButton(withTitle: "Reveal in Finder")
        a.addButton(withTitle: "Quit")
        if a.runModal() == .alertFirstButtonReturn {
            // Reveal the bundle so the user can drag it into Applications
            // (dragging even from a translocated mount copies the real app).
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        NSApp.terminate(nil)
    }
}
