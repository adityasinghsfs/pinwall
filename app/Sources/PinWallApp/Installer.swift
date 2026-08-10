import Foundation
import AppKit

/// Installs the bundled PinWall.saver into ~/Library/Screen Savers/ so it shows
/// up by name in System Settings, then opens the Screen Saver settings pane.
enum Installer {
    static var installedURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Savers/PinWall.saver")
    }

    @discardableResult
    static func installSaver() -> String {
        let fm = FileManager.default
        guard let src = Bundle.main.url(forResource: "PinWall", withExtension: "saver") else {
            return "Bundled screensaver not found inside the app."
        }
        let destDir = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Savers", isDirectory: true)
        let dest = destDir.appendingPathComponent("PinWall.saver")
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
            stripQuarantine(dest)
            openScreenSaverSettings()
            return "Installed. Choose “PinWall” in System Settings → Screen Saver."
        } catch {
            return "Install failed: \(error.localizedDescription)"
        }
    }

    private static func stripQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? p.run(); p.waitUntilExit()
    }

    /// Installs a LaunchAgent that runs `PinWall --harvest` ~hourly (and at login)
    /// to refresh the feed. Battery is handled inside the harvester via the
    /// "Start only on charger" setting, mirroring the old launchd job.
    @discardableResult
    static func installHarvestAgent() -> Bool {
        guard let exec = Bundle.main.executableURL?.path else { return false }
        let label = "work.adityasingh.pinwall.harvest"
        let agents = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let plistURL = agents.appendingPathComponent("\(label).plist")
        let log = PinWall.logFile.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(exec)</string>
            <string>--harvest</string>
          </array>
          <key>StartInterval</key><integer>3600</integer>
          <key>RunAtLoad</key><true/>
          <key>StandardOutPath</key><string>\(log)</string>
          <key>StandardErrorPath</key><string>\(log)</string>
        </dict>
        </plist>
        """
        do {
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch { return false }
        launchctl(["unload", plistURL.path])   // ignore failure (may not be loaded)
        return launchctl(["load", "-w", plistURL.path])
    }

    /// Stops and removes the harvest LaunchAgent (used on logout).
    static func removeHarvestAgent() {
        let label = "work.adityasingh.pinwall.harvest"
        let plistURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(label).plist")
        launchctl(["unload", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    /// Starts the macOS screensaver full-screen (the system engine runs whichever
    /// saver is currently selected — so install + select PinWall first for it to
    /// show PinWall). Exits on mouse move / key press like a normal screensaver.
    static func startScreenSaver() {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openScreenSaverSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension", // Ventura+
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"  // older
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}
