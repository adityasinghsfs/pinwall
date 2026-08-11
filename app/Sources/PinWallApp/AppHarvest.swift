import AppKit
import WebKit

/// Foreground, in-process harvest used when the user switches source in the app
/// (or asks to refresh). Spins up an off-screen WKWebView in the running app,
/// scrapes the chosen source, saves pins, and calls back — without exiting.
@MainActor
enum AppHarvest {
    private static var window: NSWindow?
    private static var scraper: PinterestScraper?
    private static var running = false

    static func run(source: String, completion: @escaping (Int) -> Void) {
        guard !running else { completion(0); return }
        running = true

        let frame = NSRect(x: -20_000, y: -20_000, width: 1400, height: 900)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size),
                            configuration: WKWebViewConfiguration())
        win.contentView = web
        win.orderBack(nil)
        window = win

        let s = PinterestScraper(web: web)
        scraper = s
        let target = Int(WallSettings.load().pinTarget)
        Task { @MainActor in
            let (pins, loggedIn) = await s.run(sourceURL: FeedSource.url(for: source),
                                               target: target, maxScrolls: max(60, target),
                                               needsLoad: true)
            if loggedIn && pins.count >= PinterestScraper.minPins { PinStore.save(pins) }
            cleanup()
            completion(pins.count)
        }
    }

    /// Re-discovers the user's boards in the background and saves them.
    static func refreshBoards(completion: @escaping ([Board]) -> Void) {
        guard !running else { completion(BoardStore.load()); return }
        running = true

        let frame = NSRect(x: -20_000, y: -20_000, width: 1400, height: 900)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size),
                            configuration: WKWebViewConfiguration())
        win.contentView = web
        win.orderBack(nil)
        window = win

        let s = PinterestScraper(web: web)
        scraper = s
        Task { @MainActor in
            let boards = await s.discoverBoards()
            if !boards.isEmpty { BoardStore.save(boards) }
            cleanup()
            completion(boards)
        }
    }

    private static func cleanup() {
        window?.orderOut(nil); window = nil; scraper = nil; running = false
    }
}
