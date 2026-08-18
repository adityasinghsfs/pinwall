import SwiftUI
import AppKit

/// A friendly "here's what you just unlocked" card, shown once after an update
/// (never on a first-ever install). Curated highlights, not changelog logs.
struct WhatsNewFeature: Identifiable {
    let id = UUID()
    let icon: String      // SF Symbol
    let title: String
    let blurb: String
}

@MainActor
enum WhatsNew {
    /// Highlights per version, newest first. Add an entry each release.
    static let byVersion: [(version: String, features: [WhatsNewFeature])] = [
        ("1.1.2", [
            WhatsNewFeature(icon: "arrow.down.circle",
                            title: "Updates just happen",
                            blurb: "New versions now install themselves and relaunch — no more dragging PinWall from a window."),
        ]),
        ("1.1.1", [
            WhatsNewFeature(icon: "wand.and.stars",
                            title: "Silky-smooth reveals",
                            blurb: "Your wall now fades in as one clean sweep — no more images blinking in at random."),
        ]),
        ("1.1.0", [
            WhatsNewFeature(icon: "photo.on.rectangle.angled",
                            title: "iCloud albums, too",
                            blurb: "Point PinWall at a shared iCloud album and your own photos become the wall."),
            WhatsNewFeature(icon: "square.grid.2x2",
                            title: "A whole new panel",
                            blurb: "Redesigned settings — cleaner dials, tidy folders, and a properly premium feel."),
            WhatsNewFeature(icon: "arrow.left.arrow.right",
                            title: "Switch on the fly",
                            blurb: "Flip between Pinterest and iCloud in a tap — the wall swaps with your intro animation."),
        ]),
    ]

    private static let lastSeenKey = "lastSeenVersion"
    private static var window: NSWindow?

    static func presentIfNeeded(current: String, hasPriorData: Bool) {
        let d = UserDefaults(suiteName: PinWall.suiteName)
        let last = d?.string(forKey: lastSeenKey)
        d?.set(current, forKey: lastSeenKey)   // always record what we're on now

        let feats: [WhatsNewFeature]
        if let last {
            guard isNewer(current, than: last) else { return }          // same/older → nothing new
            feats = byVersion.filter { isNewer($0.version, than: last) }.flatMap { $0.features }
        } else if hasPriorData {
            // Updated from a version that predates this feature (has real data,
            // so not a fresh install) — show the recent highlights once.
            feats = byVersion.flatMap { $0.features }
        } else {
            return   // brand-new install: don't nag
        }
        guard !feats.isEmpty else { return }

        // let the main window settle first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { show(version: current, features: feats) }
    }

    private static func show(version: String, features: [WhatsNewFeature]) {
        if window != nil { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(red: 0.04, green: 0.03, blue: 0.03, alpha: 1)
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(
            rootView: WhatsNewView(version: version, features: features) { window?.close(); window = nil }
        )
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

private struct WhatsNewView: View {
    let version: String
    let features: [WhatsNewFeature]
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .padding(.bottom, 6)
                Text("What's new")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Dial.accent)
                Text("PinWall just got better")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Dial.textRoot)
                Text("You're now on \(version). Here's what you've unlocked:")
                    .font(.system(size: 13))
                    .foregroundStyle(Dial.textMuted)
            }
            .padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)

            VStack(spacing: 12) {
                ForEach(features) { f in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: f.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Dial.accent)
                            .frame(width: 38, height: 38)
                            .background(Dial.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Dial.stroke, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Dial.textRoot)
                            Text(f.blurb).font(.system(size: 12.5)).foregroundStyle(Dial.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 20)

            Button(action: onDone) {
                Text("Let's go").frame(maxWidth: .infinity)
            }
            .buttonStyle(DialButtonStyle(accent: true))
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .frame(width: 420, height: 520, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.03, blue: 0.05),
                                    Color(red: 0.04, green: 0.03, blue: 0.03)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}
