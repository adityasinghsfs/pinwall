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
        alert.informativeText = "You have \(current). Download the new version?"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let dmg = release.dmg {
            Task { await download(dmg) }
        } else if let page = release.page {
            NSWorkspace.shared.open(page)   // no dmg asset — just open the release page
        }
    }

    private func download(_ url: URL) async {
        statusText = "Downloading…"
        guard let (tmp, _) = try? await URLSession.shared.download(from: url) else {
            statusText = "Download failed"; return
        }
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: tmp, to: dest)
        statusText = "Downloaded"
        NSWorkspace.shared.open(dest)   // mount the dmg; user drags PinWall to /Applications
    }
}
