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

    private enum UpdateError: Error { case translocated, noApp, command(String) }

    /// Downloads the release DMG, swaps it over the running bundle in place, and
    /// relaunches — no mounting/dragging. Any failure falls back to opening the
    /// DMG so the user can install it the manual way.
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
        let ok = await Task.detached(priority: .userInitiated) {
            (try? Updater.installFromDMG(dmg, installURL: installURL, translocated: translocated)) != nil
        }.value

        if ok {
            statusText = "Restarting…"
            relaunch(installURL)
        } else {
            // Couldn't self-install (not writable / translocated / bad DMG) —
            // fall back to the manual installer so the update still lands.
            statusText = "Opening installer…"
            NSWorkspace.shared.open(dmg)
        }
    }

    // MARK: - in-place install

    /// Mounts the DMG, stages the new PinWall.app on the install volume, and
    /// atomically replaces the running bundle. Throws on any failure so the
    /// caller can fall back to a manual install.
    private nonisolated static func installFromDMG(_ dmg: URL, installURL: URL, translocated: Bool) throws {
        // A translocated (quarantined) app runs from an ephemeral read-only path;
        // replacing that does nothing useful. Force the manual path instead.
        if translocated { throw UpdateError.translocated }
        let fm = FileManager.default

        let mount = URL(fileURLWithPath: "/private/tmp/PinWallUpdate.mnt")
        try? fm.removeItem(at: mount)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify",
                                     "-mountpoint", mount.path, "-quiet"])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) }

        let newApp = mount.appendingPathComponent("PinWall.app")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.noApp }

        // Stage a copy on the SAME volume as the install so the swap is atomic.
        let staging = installURL.deletingLastPathComponent().appendingPathComponent(".PinWallUpdate")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let staged = staging.appendingPathComponent("PinWall.app")
        try fm.copyItem(at: newApp, to: staged)
        // Strip the download quarantine so the relaunched app isn't translocated.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        // Atomic in-place replacement of the (running) bundle.
        _ = try fm.replaceItemAt(installURL, withItemAt: staged)
        try? fm.removeItem(at: staging)
    }

    /// Quits this instance and relaunches the freshly-installed bundle.
    private func relaunch(_ appURL: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for THIS process to exit, then reopen the updated app.
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"\(appURL.path)\""]
        try? p.run()
        NSApp.terminate(nil)
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
