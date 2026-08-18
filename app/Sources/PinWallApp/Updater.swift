import Foundation
import AppKit

/// Checks GitHub Releases for a newer PinWall on launch and on demand. When a
/// newer version exists it offers to download the release's .dmg and open it.
/// (Conservative by design — no silent self-replace; the user drops the new app
/// into /Applications. Sparkle would be the upgrade path for fully-silent updates.)
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    @Published var statusText = "Check for updates"

    private var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    private var latestURL: URL {
        URL(string: "https://api.github.com/repos/\(PinWall.repo)/releases/latest")!
    }

    func checkOnLaunch() { Task { await check(interactive: false) } }
    func checkNow() { Task { await check(interactive: true) } }

    private func check(interactive: Bool) async {
        statusText = "Checking…"
        guard let release = await fetchLatest() else {
            statusText = interactive ? "No releases yet" : "Check for updates"
            return
        }
        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        if isNewer(latest, than: current) {
            statusText = "Update available: \(release.tag)"
            offerUpdate(release)
        } else {
            statusText = interactive ? "You’re up to date" : "Check for updates"
        }
    }

    // MARK: - GitHub

    private struct Release { let tag: String; let dmg: URL?; let page: URL? }

    private func fetchLatest() async -> Release? {
        var req = URLRequest(url: latestURL)
        req.setValue("PinWall-Updater", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }
        var dmg: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            for a in assets {
                if let name = a["name"] as? String, name.lowercased().hasSuffix(".dmg"),
                   let s = a["browser_download_url"] as? String { dmg = URL(string: s); break }
            }
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        return Release(tag: tag, dmg: dmg, page: page)
    }

    // MARK: - version compare (numeric, dot-separated)

    private func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - offer

    private func offerUpdate(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "PinWall \(release.tag) is available"
        alert.informativeText = "You have \(current). PinWall will download it, install it, and restart."
        alert.addButton(withTitle: "Update & Restart")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let dmg = release.dmg {
            Task { await downloadAndInstall(dmg) }
        } else if let page = release.page {
            NSWorkspace.shared.open(page)   // no dmg asset — just open the release page
        }
    }

    private enum UpdateError: Error { case translocated, notWritable, noApp, command(String) }

    /// Downloads the release DMG, stages the new app next to the install, then
    /// hands a tiny helper the job of swapping it in AFTER we quit and relaunching.
    /// Doing the replace post-quit is what makes it reliable: while the app runs,
    /// its executable + frameworks are memory-mapped and an in-place swap fails
    /// (which is why the old path fell back to a manual drag). Any real failure
    /// falls back to opening the DMG so the update still lands.
    private func downloadAndInstall(_ url: URL) async {
        statusText = "Downloading…"
        guard let (tmp, _) = try? await URLSession.shared.download(from: url) else {
            statusText = "Download failed"; return
        }
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("PinWall-update.dmg")
        try? FileManager.default.removeItem(at: dmg)
        guard (try? FileManager.default.moveItem(at: tmp, to: dmg)) != nil else {
            statusText = "Download failed"; return
        }

        statusText = "Installing…"
        let installURL = Bundle.main.bundleURL   // e.g. /Applications/PinWall.app
        let translocated = PinWall.isTranslocated
        let scriptURL: URL? = await Task.detached(priority: .userInitiated) {
            try? Updater.stageUpdate(dmg: dmg, installURL: installURL, translocated: translocated)
        }.value

        if let scriptURL {
            statusText = "Restarting…"
            launchSwapAndQuit(scriptURL)
        } else {
            // Not writable / translocated / bad DMG — fall back to the manual
            // installer so the update still lands.
            statusText = "Opening installer…"
            NSWorkspace.shared.open(dmg)
        }
    }

    // MARK: - staged, deferred install

    /// Mounts the DMG, copies the new app to a staging dir on the install volume,
    /// and writes a helper script that (after we quit) replaces the bundle and
    /// reopens it. Returns the script URL, or throws so the caller falls back.
    private nonisolated static func stageUpdate(dmg: URL, installURL: URL, translocated: Bool) throws -> URL {
        if translocated { throw UpdateError.translocated }
        let fm = FileManager.default
        let parent = installURL.deletingLastPathComponent()
        // Must be able to write where the app lives, or the swap can't happen.
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }

        // clean any stale mount from a previous attempt
        let mount = URL(fileURLWithPath: "/private/tmp/PinWallUpdate.mnt")
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        try? fm.removeItem(at: mount)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify",
                                     "-mountpoint", mount.path, "-quiet"])

        let newApp = mount.appendingPathComponent("PinWall.app")
        guard fm.fileExists(atPath: newApp.path) else {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            throw UpdateError.noApp
        }

        // Copy the new app onto the install volume (so the later mv is a fast,
        // same-volume rename), then detach the DMG — the swap won't need it.
        let staged = parent.appendingPathComponent(".PinWallUpdate.app")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: newApp, to: staged)
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Helper: wait for our PID to die, swap the bundle, relaunch.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.15; done
        sleep 0.2
        /bin/rm -rf \(shq(installURL.path))
        /bin/mv \(shq(staged.path)) \(shq(installURL.path))
        /usr/bin/xattr -dr com.apple.quarantine \(shq(installURL.path)) 2>/dev/null
        /usr/bin/open \(shq(installURL.path))
        """
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("pinwall-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        return scriptURL
    }

    /// Detach the helper (so it survives our exit), then quit.
    private func launchSwapAndQuit(_ scriptURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        try? p.run()   // NOT waited on — it outlives us and does the swap
        // give the helper a beat to start watching our PID, then quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    /// Single-quote a path for safe shell interpolation.
    private nonisolated static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private nonisolated static func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UpdateError.command("\(path) exited \(p.terminationStatus)")
        }
        return p.terminationStatus
    }
}
