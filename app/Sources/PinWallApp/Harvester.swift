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
        // classic bot fingerprint. Same trick as the original Python harvester:
        // launchd fires on the interval, we sleep a random 0–40% of it first,
        // so a 30-min slot lands at ~30–42 min gaps that drift every cycle.
        let jitter = Double.random(in: 0...(settings.refreshMins * 60 * 0.4))
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
        let line = "\(isoNow()) \(message)\n"
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: PinWall.logFile) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: PinWall.logFile)
            }
        }
        FileHandle.standardError.write(Data(line.utf8))
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
        // hard timeout so a hung scrape can't leave the process alive forever
        // (scaled: 300 pins needs many more scroll rounds than 100)
        let timeout = max(300.0, WallSettings.load().pinTarget * 2.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            Harvester.log("timed out after \(Int(timeout))s"); exit(2)
        }

        let frame = NSRect(x: -20_000, y: -20_000, width: 1400, height: 900)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size),
                            configuration: WKWebViewConfiguration())
        win.contentView = web
        win.orderBack(nil)   // off-screen, don't steal focus
        self.window = win

        let scraper = PinterestScraper(web: web)
        self.scraper = scraper
        let settings = WallSettings.load()
        Task { @MainActor in
            let (pins, loggedIn) = await scraper.run(sourceURL: FeedSource.url(for: settings.source),
                                                     target: Int(settings.pinTarget),
                                                     maxScrolls: max(60, Int(settings.pinTarget)),
                                                     needsLoad: true)
            if loggedIn && pins.count >= PinterestScraper.minPins {
                PinStore.save(pins)
                Harvester.log("harvested \(pins.count) pins")
            } else {
                Harvester.log("only \(pins.count) pins / logged out — kept existing pins.json")
            }
            exit(0)
        }
    }
}
