import Foundation
import IOKit.ps

/// Shared constants + storage locations used by BOTH the app and the screensaver.
/// Compiled into each target (a .saver can't easily embed a framework), so this
/// file must stay dependency-free: Foundation only, no SwiftUI / ScreenSaver.
public enum PinWall {
    /// UserDefaults suite both processes read/write (lives in ~/Library/Preferences).
    /// Must NOT equal either bundle id, or macOS refuses it ("using your own
    /// bundle identifier as a suite name … will not work").
    public static let suiteName = "work.adityasingh.pinwall.shared"
    public static let appBundleID = "work.adityasingh.pinwall"
    /// GitHub repo the updater and (optionally) a curated feed come from.
    public static let repo = "adityasinghsfs/pinwall"

    /// Support dir as resolved for THIS process. NOTE: inside the sandboxed
    /// screensaver host (legacyScreenSaver.appex) this resolves into the appex's
    /// CONTAINER, not the user's real home — fine for logs, useless for sharing.
    public static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PinWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    public static var pinsFile: URL { supportDir.appendingPathComponent("pins.json") }
    public static var logFile: URL { supportDir.appendingPathComponent("harvest.log") }

    /// True when this process runs inside an app-sandbox container (the
    /// legacyScreenSaver appex that hosts third-party savers on macOS 14+).
    public static var inSandboxContainer: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }

    /// The user's REAL home, even from inside a sandbox container (where
    /// NSHomeDirectory() lies). getpwuid reports the account's actual home.
    public static var realHomeDir: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        // Fallback: strip the sandbox-container suffix off NSHomeDirectory()
        // (…/Library/Containers/<id>/Data) so we don't resolve back into it.
        let home = NSHomeDirectory()
        if let r = home.range(of: "/Library/Containers/") {
            return URL(fileURLWithPath: String(home[..<r.lowerBound]), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// True when macOS is running the app from a read-only, ephemeral
    /// AppTranslocation path (Gatekeeper does this to quarantined apps launched
    /// from a DMG / Downloads). The path vanishes on eject, so we must NOT record
    /// it in the LaunchAgent or the saver's app-path.
    public static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    // MARK: - harvest status (surfaced in the app so a stale feed isn't silent)

    private static var suite: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// Record the outcome of a harvest so the app can show "reconnect" / staleness.
    public static func recordHarvest(loggedIn: Bool, saved: Bool) {
        let d = suite
        d?.set(Date().timeIntervalSince1970, forKey: "lastHarvestAttempt")
        if saved {
            d?.set(0, forKey: "harvestFailStreak")
            d?.set(false, forKey: "harvestLoggedOut")
        } else {
            d?.set((d?.integer(forKey: "harvestFailStreak") ?? 0) + 1, forKey: "harvestFailStreak")
            d?.set(!loggedIn, forKey: "harvestLoggedOut")
        }
    }
    /// The last harvest found the session logged out — the user must reconnect.
    public static var harvestLoggedOut: Bool { suite?.bool(forKey: "harvestLoggedOut") ?? false }

    /// Where the app PUBLISHES the wall for the sandboxed screensaver:
    /// plain files in the real home (pinwall.html + pins.js + settings.js).
    /// The appex can't see our UserDefaults or per-process Application Support
    /// (it has its own container), but it holds a read-only exception for the
    /// whole disk — so a file:// page with sibling .js data files is the one
    /// data path PROVEN to work there (it's how WebViewScreenSaver ran for months).
    public static var saverWebDir: URL {
        realHomeDir.appendingPathComponent("Library/Application Support/PinWall/web", isDirectory: true)
    }

    /// Regenerate the published mirror. Called by the app on launch and after
    /// every settings/pins change. No-op inside the sandboxed saver, and skipped
    /// when translocated (the app-path would be an ephemeral, disappearing URL).
    ///
    /// Writes into a temp dir and atomically swaps it into place so a saver that
    /// starts mid-publish never pairs new html with stale/absent settings.js.
    public static func publishSaverMirror() {
        guard !inSandboxContainer, !isTranslocated else { return }
        let fm = FileManager.default
        let dir = saverWebDir
        let parent = dir.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tmp = parent.appendingPathComponent("web.tmp-\(getpid())", isDirectory: true)
        try? fm.removeItem(at: tmp)
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return }

        if let src = Bundle.main.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "pinwall", withExtension: "html"),
           let html = try? Data(contentsOf: src) {
            try? html.write(to: tmp.appendingPathComponent("pinwall.html"))
        }
        let settings = WallSettings.load()
        let pins = PinStore.load()
        // No pins → skeleton (shimmer), NEVER the demo picsum wall: the
        // screensaver must not pull random internet stock photos onto a lock
        // screen. Real pins → the wall.
        let cfg = "window.PINWALL_CONFIG = "
            + settings.configJSON(gallery: false, skeleton: pins.isEmpty, app: false, reload: true) + ";\n"
        try? cfg.data(using: .utf8)?.write(to: tmp.appendingPathComponent("settings.js"))
        let pjs = "window.PINS = " + PinStore.pinsJSON(pins) + ";\n"
        try? pjs.data(using: .utf8)?.write(to: tmp.appendingPathComponent("pins.js"))
        try? Bundle.main.bundlePath.data(using: .utf8)?
            .write(to: tmp.appendingPathComponent("apppath.txt"))

        // atomic swap: web.tmp -> web (replaceItemAt handles the existing dir)
        if fm.fileExists(atPath: dir.path) {
            _ = try? fm.replaceItemAt(dir, withItemAt: tmp)
        } else {
            try? fm.moveItem(at: tmp, to: dir)
        }
        try? fm.removeItem(at: tmp)
    }
}

/// A machine-wide lock so only one harvest (headless LaunchAgent OR in-app)
/// touches the shared WebKit cookie/data store at a time. O_EXCL create is
/// atomic across processes; stale locks (crashed holder) break after 10 min.
public enum HarvestLock {
    private static var file: URL { PinWall.supportDir.appendingPathComponent("harvest.lock") }
    public static func acquire() -> Bool {
        let path = file.path
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) > 600 {
            try? FileManager.default.removeItem(atPath: path)
        }
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd == -1 { return false }
        close(fd)
        return true
    }
    public static func release() { try? FileManager.default.removeItem(at: file) }
}

/// One pin: the image URL plus the Pinterest link it opens in gallery mode.
public struct Pin: Codable, Equatable {
    public var img: String
    public var link: String
    public init(img: String, link: String = "") { self.img = img; self.link = link }
}

public enum PinStore {
    public static func load() -> [Pin] {
        guard let data = try? Data(contentsOf: PinWall.pinsFile) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
    }
    public static func save(_ pins: [Pin]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        try? data.write(to: PinWall.pinsFile, options: .atomic)
        UserDefaults(suiteName: PinWall.suiteName)?
            .set(Date().timeIntervalSince1970, forKey: "lastRefresh")
        PinWall.publishSaverMirror()   // keep the screensaver's file mirror fresh
    }
    /// When the feed was last successfully refreshed (nil = never).
    public static var lastRefresh: Date? {
        let t = UserDefaults(suiteName: PinWall.suiteName)?.double(forKey: "lastRefresh") ?? 0
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    // MARK: per-provider caches — so switching Pinterest ↔ iCloud swaps the wall
    // instantly from cache instead of waiting for a fresh harvest.

    private static func cacheFile(for provider: String) -> URL {
        PinWall.supportDir.appendingPathComponent("pins-\(provider).json")
    }
    public static func loadCache(for provider: String) -> [Pin] {
        // Pure cache read — NO fallback to the active pins.json here: at switch
        // time pins.json holds the OUTGOING provider's wall, and falling back
        // would leak it into (or wipe) the other provider's cache. Migration is
        // handled by snapshotting the active wall before every switch.
        guard let data = try? Data(contentsOf: cacheFile(for: provider)),
              let pins = try? JSONDecoder().decode([Pin].self, from: data) else { return [] }
        return pins
    }
    public static func saveCache(_ pins: [Pin], for provider: String) {
        // An empty write NEVER overwrites a cache — an empty active wall must
        // not be able to wipe a provider's good feed. Explicit removal goes
        // through clearCache (unlink).
        guard !pins.isEmpty, let data = try? JSONEncoder().encode(pins) else { return }
        try? data.write(to: cacheFile(for: provider), options: .atomic)
    }
    public static func clearCache(for provider: String) {
        try? FileManager.default.removeItem(at: cacheFile(for: provider))
    }
    /// Saves to BOTH the provider's cache and (when that provider is active)
    /// the live wall. Harvests call this instead of save().
    public static func save(_ pins: [Pin], cacheFor provider: String) {
        saveCache(pins, for: provider)
        if WallSettings.load().provider == provider { save(pins) }
    }
    /// Makes `provider`'s cached pins the live wall. Returns how many it had.
    @discardableResult
    public static func activate(provider: String) -> Int {
        let pins = loadCache(for: provider)
        save(pins)
        return pins.count
    }
    /// JSON array literal for injecting into the page as `window.PINS`.
    public static func pinsJSON(_ pins: [Pin]) -> String {
        guard let data = try? JSONEncoder().encode(pins),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}

/// One of the user's Pinterest boards (for the source dropdown).
public struct Board: Codable, Equatable {
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public enum BoardStore {
    private static var file: URL { PinWall.supportDir.appendingPathComponent("boards.json") }
    public static func load() -> [Board] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([Board].self, from: data)) ?? []
    }
    public static func save(_ boards: [Board]) {
        guard let data = try? JSONEncoder().encode(boards) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

/// The feed source to harvest: the home feed, or a specific board URL.
public enum FeedSource {
    public static let feed = "feed"   // sentinel stored in settings.source
    public static func url(for source: String) -> URL {
        if source == feed || source.isEmpty { return URL(string: "https://www.pinterest.com/")! }
        return URL(string: source) ?? URL(string: "https://www.pinterest.com/")!
    }
}

/// Wall tuning + behaviour, shared through the UserDefaults suite.
/// (Named WallSettings, not Settings, to avoid colliding with SwiftUI.Settings.)
public struct WallSettings: Equatable {
    public var speed: Double
    public var fade: Double
    public var rise: Double
    public var stagger: Double
    public var columns: Double     // number of vertical columns in the wall (3–10)
    public var topBlur: Double     // (unused — kept for settings compat)
    public var chroma: Double      // (unused — kept for settings compat)
    public var clock: Bool         // show a clock + date overlay
    public var clockPos: String    // clock position: tl tc tr cl cc cr bl bc br
    public var clockSize: Double   // clock scale, percent (60–160)
    public var clockDate: Bool     // show the date line under the time
    public var clockFont: String   // system | rounded | serif | mono
    public var clockWeight: Double // time font weight (100–900)
    public var clockGlass: Bool    // frosted glass panel behind the clock
    public var clockColor: String  // hex "#RRGGBB"
    public var chargerOnly: Bool   // "Refresh only on charger": skip harvest on battery
    public var refreshMins: Double // feed refresh interval in minutes (LaunchAgent)
    public var pinTarget: Double   // how many pins each refresh collects
    public var connected: Bool     // has the user connected their Pinterest?
    public var source: String      // "feed" or a board URL to harvest from
    public var introStyle: String  // entrance: "bloom" | "radial" | "radialDots"
    public var introOrigin: String // radial reveal origin: "bc" | "bl" | "br"
    public var introMs: Double     // intro duration in ms (1000–3000)
    public var feedAngle: Double   // tilt the scrolling axis, degrees (-30…30, 0 = straight)
    public var provider: String    // photo source: "pinterest" | "icloud"
    public var icloudURL: String   // public iCloud Shared Album link ("" = not linked)

    public init(speed: Double, fade: Double, rise: Double, stagger: Double,
                columns: Double, topBlur: Double, chroma: Double,
                clock: Bool, clockPos: String, clockSize: Double, clockDate: Bool,
                clockFont: String, clockWeight: Double, clockGlass: Bool, clockColor: String,
                chargerOnly: Bool, refreshMins: Double = 60, pinTarget: Double = 100,
                connected: Bool, source: String,
                introStyle: String = "bloom", introOrigin: String = "bc", introMs: Double = 1800,
                feedAngle: Double = 0,
                provider: String = "pinterest", icloudURL: String = "") {
        self.speed = speed; self.fade = fade; self.rise = rise; self.stagger = stagger
        self.columns = columns; self.topBlur = topBlur; self.chroma = chroma
        self.clock = clock; self.clockPos = clockPos; self.clockSize = clockSize; self.clockDate = clockDate
        self.clockFont = clockFont; self.clockWeight = clockWeight
        self.clockGlass = clockGlass; self.clockColor = clockColor
        self.chargerOnly = chargerOnly
        self.refreshMins = refreshMins; self.pinTarget = pinTarget
        self.connected = connected
        self.source = source
        self.introStyle = introStyle
        self.introOrigin = introOrigin
        self.introMs = introMs
        self.feedAngle = feedAngle
        self.provider = provider
        self.icloudURL = icloudURL
    }

    /// Tuning defaults (everything except the Pinterest connection).
    public static let defaultSpeed = 24.0, defaultFade = 300.0, defaultRise = 24.0
    public static let defaultStagger = 350.0, defaultColumns = 5.0

    public static let fallback = WallSettings(speed: defaultSpeed, fade: defaultFade,
        rise: defaultRise, stagger: defaultStagger, columns: defaultColumns,
        topBlur: 0, chroma: 0,
        clock: false, clockPos: "tc", clockSize: 100, clockDate: true,
        clockFont: "system", clockWeight: 200, clockGlass: false, clockColor: "#FFFFFF",
        chargerOnly: false, connected: false, source: FeedSource.feed)

    /// Reset the look/motion to defaults but keep the Pinterest connection + clock on/off.
    public mutating func resetTuning() {
        speed = Self.defaultSpeed; fade = Self.defaultFade; rise = Self.defaultRise
        stagger = Self.defaultStagger; columns = Self.defaultColumns
        topBlur = 0; chroma = 0
        clockPos = "tc"; clockSize = 100; clockDate = true
        clockFont = "system"; clockWeight = 200; clockGlass = false; clockColor = "#FFFFFF"
        chargerOnly = false; refreshMins = 60; pinTarget = 100
        introStyle = "bloom"; introOrigin = "bc"; introMs = 1800; feedAngle = 0
    }

    private static var store: UserDefaults { UserDefaults(suiteName: PinWall.suiteName) ?? .standard }

    public static func load() -> WallSettings {
        let d = store
        func dbl(_ k: String, _ f: Double) -> Double { d.object(forKey: k) == nil ? f : d.double(forKey: k) }
        return WallSettings(
            speed: dbl("speed", defaultSpeed), fade: dbl("fade", defaultFade),
            rise: dbl("rise", defaultRise), stagger: dbl("stagger", defaultStagger),
            columns: dbl("columns", defaultColumns),
            topBlur: dbl("topBlur", 0), chroma: dbl("chroma", 0),
            clock: d.bool(forKey: "clock"),
            clockPos: d.string(forKey: "clockPos") ?? "tc",
            clockSize: dbl("clockSize", 100),
            clockDate: d.object(forKey: "clockDate") == nil ? true : d.bool(forKey: "clockDate"),
            clockFont: d.string(forKey: "clockFont") ?? "system",
            clockWeight: dbl("clockWeight", 200),
            clockGlass: d.bool(forKey: "clockGlass"),
            clockColor: d.string(forKey: "clockColor") ?? "#FFFFFF",
            chargerOnly: d.bool(forKey: "chargerOnly"),
            refreshMins: dbl("refreshMins", 60), pinTarget: dbl("pinTarget", 100),
            connected: d.bool(forKey: "connected"),
            source: d.string(forKey: "source") ?? FeedSource.feed,
            introStyle: d.string(forKey: "introStyle") ?? "bloom",
            introOrigin: d.string(forKey: "introOrigin") ?? "bc",
            introMs: dbl("introMs", 1800),
            feedAngle: dbl("feedAngle", 0),
            provider: d.string(forKey: "provider") ?? "pinterest",
            icloudURL: d.string(forKey: "icloudURL") ?? "")
    }
    public func save() {
        let d = WallSettings.store
        d.set(speed, forKey: "speed"); d.set(fade, forKey: "fade")
        d.set(rise, forKey: "rise"); d.set(stagger, forKey: "stagger")
        d.set(columns, forKey: "columns")
        d.set(topBlur, forKey: "topBlur"); d.set(chroma, forKey: "chroma")
        d.set(clock, forKey: "clock"); d.set(clockPos, forKey: "clockPos")
        d.set(clockSize, forKey: "clockSize"); d.set(clockDate, forKey: "clockDate")
        d.set(clockFont, forKey: "clockFont"); d.set(clockWeight, forKey: "clockWeight")
        d.set(clockGlass, forKey: "clockGlass"); d.set(clockColor, forKey: "clockColor")
        d.set(chargerOnly, forKey: "chargerOnly")
        d.set(refreshMins, forKey: "refreshMins"); d.set(pinTarget, forKey: "pinTarget")
        d.set(connected, forKey: "connected")
        d.set(source, forKey: "source")
        d.set(introStyle, forKey: "introStyle")
        d.set(introOrigin, forKey: "introOrigin")
        d.set(introMs, forKey: "introMs")
        d.set(feedAngle, forKey: "feedAngle")
        d.set(provider, forKey: "provider")
        d.set(icloudURL, forKey: "icloudURL")
        PinWall.publishSaverMirror()   // keep the screensaver's file mirror fresh
    }
    /// Object literal for injecting into the page as `window.PINWALL_CONFIG`.
    /// `app` = running inside PinWall.app (keep the cursor visible); the
    /// screensaver passes false so the cursor stays hidden while it's showing.
    public func configJSON(gallery: Bool, skeleton: Bool, app: Bool,
                           hideWall: Bool = false, reload: Bool = false) -> String {
        // Serialize properly so string fields (clockPos/clockFont/clockColor) are
        // escaped — a stray quote/backslash would otherwise produce invalid JS
        // and blank the wall / break in-app injection.
        // One "Intro duration" drives everything: radial/dots use it directly
        // (revealMs); Bloom's per-tile fade + stagger are derived from it.
        let dict: [String: Any] = [
            "speed": speed, "columns": columns,
            "fade": introMs * 0.30, "rise": 24, "stagger": introMs * 0.55,
            "revealMs": introMs,
            "clock": clock, "clockPos": clockPos,
            "clockSize": clockSize, "clockDate": clockDate,
            "clockFont": clockFont, "clockWeight": clockWeight,
            "clockGlass": clockGlass, "clockColor": clockColor,
            "introStyle": introStyle, "introOrigin": introOrigin, "feedAngle": feedAngle,
            "gallery": gallery, "skeleton": skeleton, "app": app,
            "hideWall": hideWall, "reload": reload,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }
}

/// The script injected at documentStart so the page boots straight from native
/// data instead of fetching pins.js over file:// (which is CORS-blocked).
public func pinwallBootstrapJS(pins: [Pin], settings: WallSettings,
                               gallery: Bool, skeleton: Bool, app: Bool,
                               hideWall: Bool = false) -> String {
    """
    window.PINS = \(PinStore.pinsJSON(pins));
    window.PINWALL_CONFIG = \(settings.configJSON(gallery: gallery, skeleton: skeleton, app: app, hideWall: hideWall));
    """
}

/// True when running on the internal battery. Uses IOKit (no process spawn),
/// so it works inside the sandboxed screensaver host. Desktops (no battery)
/// report false → always treated as "on AC".
public func onBatteryPower() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return false }
    for source in list {
        guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let state = desc[kIOPSPowerSourceStateKey as String] as? String else { continue }
        if state == (kIOPSBatteryPowerValue as String) { return true }
    }
    return false
}
