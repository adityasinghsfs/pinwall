import Foundation
import AppKit

/// Installs the bundled PinWall.saver into ~/Library/Screen Savers/ so it shows
/// up by name in System Settings, then opens the Screen Saver settings pane.
enum Installer {
    static let agentLabel = "work.adityasingh.pinwall.harvest"

    static var installedURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Savers/PinWall.saver")
    }
    static var agentPlistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(agentLabel).plist")
    }

    // MARK: - screensaver bundle

    @discardableResult
    static func installSaver() -> String { copySaver(openSettings: true) }

    /// Silent self-heal: if the installed saver is missing or a different version
    /// than the one bundled in this app, re-copy it (no Settings pane). Ensures
    /// screensaver bug/security fixes reach users when the APP updates.
    static func syncSaverIfNeeded() {
        guard let bundled = Bundle.main.url(forResource: "PinWall", withExtension: "saver") else { return }
        let bv = version(of: bundled)
        let iv = version(of: installedURL)
        if iv == nil || iv != bv { _ = copySaver(openSettings: false) }
    }

    @discardableResult
    private static func copySaver(openSettings: Bool) -> String {
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
            if openSettings { openScreenSaverSettings() }
            return "Installed. Choose “PinWall” in System Settings → Screen Saver."
        } catch {
            return "Install failed: \(error.localizedDescription)"
        }
    }

    private static func version(of saver: URL) -> String? {
        let info = saver.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: info) else { return nil }
        let short = d["CFBundleShortVersionString"] as? String ?? ""
        let build = d["CFBundleVersion"] as? String ?? ""
        return short.isEmpty && build.isEmpty ? nil : short + "/" + build
    }

    private static func stripQuarantine(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? p.run(); p.waitUntilExit()
    }

    // MARK: - harvest LaunchAgent

    /// Installs a LaunchAgent that runs `PinWall --harvest` on the chosen interval.
    /// Refuses when the app is App-Translocated (its executable path is ephemeral
    /// and would vanish on DMG eject, permanently killing the refresh).
    @discardableResult
    static func installHarvestAgent() -> Bool {
        guard !PinWall.isTranslocated else { return false }
        guard let exec = Bundle.main.executableURL?.path else { return false }
        let agents = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let log = PinWall.logFile.path
        let interval = max(900, Int(WallSettings.load().refreshMins * 60))   // floor: 15 min
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(agentLabel)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(exec)</string>
            <string>--harvest</string>
          </array>
          <key>StartInterval</key><integer>\(interval)</integer>
          <!-- interval-only: RunAtLoad would spawn a harvest the moment the app
               (re)installs the agent — including while the screensaver is up -->
          <key>RunAtLoad</key><false/>
          <key>StandardOutPath</key><string>\(log)</string>
          <key>StandardErrorPath</key><string>\(log)</string>
        </dict>
        </plist>
        """
        do { try plist.write(to: agentPlistURL, atomically: true, encoding: .utf8) }
        catch { Harvester.log("installHarvestAgent: write failed \(error.localizedDescription)"); return false }
        launchctl(["unload", agentPlistURL.path])
        let ok = launchctl(["load", "-w", agentPlistURL.path])
        if !ok { Harvester.log("installHarvestAgent: launchctl load failed") }
        return ok
    }

    static func removeHarvestAgent() {
        launchctl(["unload", agentPlistURL.path])
        try? FileManager.default.removeItem(at: agentPlistURL)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    // MARK: - uninstall

    /// Full removal: stop + delete the agent, delete the installed saver, and
    /// wipe the published mirror + support dir. Leaves the .app for the user to
    /// drag to Trash. (Also surfaced in the DMG's README.)
    static func uninstall() {
        removeHarvestAgent()
        try? FileManager.default.removeItem(at: installedURL)
        let support = PinWall.realHomeDir.appendingPathComponent("Library/Application Support/PinWall")
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: - screensaver launch / settings

    static func startScreenSaver() {
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
    }

    static func openScreenSaverSettings() {
        // On macOS 14–26 the Screen Saver picker lives inside the Wallpaper pane.
        let candidates = [
            "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",   // macOS 14–26
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension", // older
            "x-apple.systempreferences:com.apple.preference.desktopscreeneffect"  // legacy
        ]
        for c in candidates {
            if let url = URL(string: c), NSWorkspace.shared.open(url) { return }
        }
    }
}
