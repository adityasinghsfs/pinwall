import AppKit
import WebKit

/// Foreground, in-process harvest used when the user switches source in the app
/// (or asks to refresh). Spins up an off-screen WKWebView in the running app,
/// scrapes the chosen source, saves pins, and calls back — without exiting.
///
/// Honors the machine-wide HarvestLock so it never runs concurrently with the
/// headless `--harvest` LaunchAgent (they share one WebKit cookie/data store),
/// and wraps every run in a watchdog so a hung Pinterest load can't wedge it.
@MainActor
enum AppHarvest {
    private static var window: NSWindow?
    private static var scraper: PinterestScraper?
    private static var running = false
    private static var completed = false

    static func run(source: String, completion: @escaping (Int) -> Void) {
        guard !running else { completion(0); return }
        guard HarvestLock.acquire() else { completion(0); return }   // background harvest active
        begin()
        let s = makeScraper()
        let target = Int(WallSettings.load().pinTarget)
        watchdog { completion(0) }
        Task { @MainActor in
            let (pins, loggedIn) = await s.run(sourceURL: FeedSource.url(for: source),
                                               target: target, maxScrolls: max(60, target),
                                               needsLoad: true)
            // User explicitly chose this source — save whatever real pins it has
            // (a small board is valid), as long as we're genuinely logged in.
            if loggedIn && !pins.isEmpty { PinStore.save(pins) }
            done { completion(pins.count) }
        }
    }

    /// Re-discovers the user's boards. On empty/failed discovery it returns the
    /// PERSISTED list rather than [] so the caller never wipes a good dropdown.
    static func refreshBoards(completion: @escaping ([Board]) -> Void) {
        guard !running else { completion(BoardStore.load()); return }
        guard HarvestLock.acquire() else { completion(BoardStore.load()); return }
        begin()
        let s = makeScraper()
        watchdog { completion(BoardStore.load()) }
        Task { @MainActor in
            let boards = await s.discoverBoards()
            if !boards.isEmpty { BoardStore.save(boards) }
            done { completion(boards.isEmpty ? BoardStore.load() : boards) }
        }
    }

    // MARK: - harness

    private static func begin() {
        running = true; completed = false
    }
    private static func makeScraper() -> PinterestScraper {
        let frame = NSRect(x: -20_000, y: -20_000, width: 1400, height: 900)
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size),
                            configuration: WKWebViewConfiguration())
        win.contentView = web
        win.orderBack(nil)
        window = win
        let s = PinterestScraper(web: web); scraper = s; return s
    }
    private static func watchdog(_ onTimeout: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            done(onTimeout)
        }
    }
    private static func done(_ finish: () -> Void) {
        if completed { return }
        completed = true
        window?.orderOut(nil); window = nil; scraper = nil; running = false
        HarvestLock.release()
        finish()
    }
}
