import Foundation
import AppKit
import WebKit

/// Headless feed refresh, run as `PinWall.app --harvest` by the LaunchAgent.
/// Spins up an off-screen WKWebView (shared cookies from the connect flow),
/// scrapes the logged-in feed, writes pins.json, and exits.
enum Harvester {
    static func runHeadlessAndExit() -> Never {
        let settings = WallSettings.load()
        if !settings.connected { log("not connected — skipping"); exit(0) }
        if settings.chargerOnly && onBatteryPower() { log("on battery + charger-only — skipping"); exit(0) }
        // Jitter: never fetch on a robotic clock grid — exact intervals are a
        // classic bot fingerprint. Same trick as the original Python harvester.
        // Clamp: a corrupt/negative refreshMins must not trap random(in:).
        let cap = max(0, settings.refreshMins) * 60 * 0.4
        let jitter = cap > 0 ? Double.random(in: 0...cap) : 0
        log(String(format: "jitter: sleeping %.1f min before fetch", jitter / 60))
        Thread.sleep(forTimeInterval: jitter)
        if settings.chargerOnly && onBatteryPower() { log("went on battery during jitter — skipping"); exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no dock icon, no menu bar
        let delegate = HarvestDelegate()
        harvestDelegateRef = delegate
        app.delegate = delegate
        app.run()
        exit(0)
    }

    static func log(_ message: String) {
        rotateIfBig()
        let line = "\(isoNow()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        // O_APPEND so concurrent processes don't clobber each other's lines,
        // and we DON'T also write stderr (the LaunchAgent already redirects
        // stderr to this same file — writing both double-logged every line).
        let fd = open(PinWall.logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 { data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }; close(fd) }
    }

    private static func rotateIfBig() {
        let path = PinWall.logFile.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 512_000 {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func isoNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

private var harvestDelegateRef: AnyObject?

final class HarvestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var scraper: PinterestScraper?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // one harvest machine-wide — don't collide with an in-app refresh over
        // the shared cookie store.
        guard HarvestLock.acquire() else { Harvester.log("another harvest holds the lock — skipping"); exit(0) }

        // hard timeout so a hung scrape can't leave the process alive forever
        let timeout = max(300.0, WallSettings.load().pinTarget * 2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            Harvester.log("timed out after \(Int(timeout))s"); HarvestLock.release(); exit(2)
        }

        let frame = NSRect(x: -20_000, y: -20_000, width: 1400, height: 900)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size),
                            configuration: WKWebViewConfiguration())
        win.contentView = web
        win.orderBack(nil)   // off-screen, don't steal focus
        self.window = win
        // Off-screen ⇒ WebKit deems the page occluded and suspends rendering +
        // lazy image loading, so Pinterest mounts zero pins. Disable window
        // occlusion detection so the headless webview keeps rendering.
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: sel) {
            typealias SetBoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(web.method(for: sel), to: SetBoolIMP.self)(web, sel, false)
        }

        let scraper = PinterestScraper(web: web)
        self.scraper = scraper
        let settings = WallSettings.load()
        Task { @MainActor in
            let (pins, loggedIn) = await scraper.run(sourceURL: FeedSource.url(for: settings.source),
                                                     target: Int(settings.pinTarget),
                                                     maxScrolls: max(60, Int(settings.pinTarget)),
                                                     needsLoad: true)
            let saved = loggedIn && pins.count >= PinterestScraper.minPins
            if saved {
                PinStore.save(pins)
                Harvester.log("harvested \(pins.count) pins")
            } else {
                Harvester.log(loggedIn ? "only \(pins.count) pins — kept existing"
                                       : "session looks logged out — kept existing, flagged reconnect")
            }
            PinWall.recordHarvest(loggedIn: loggedIn, saved: saved)
            HarvestLock.release()
            exit(0)
        }
    }
}
