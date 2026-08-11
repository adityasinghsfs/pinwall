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
        return FileManager.default.homeDirectoryForCurrentUser
    }

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
    /// every settings/pins change. No-op inside the sandboxed saver.
    public static func publishSaverMirror() {
        guard !inSandboxContainer else { return }
        let fm = FileManager.default
        let dir = saverWebDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let src = Bundle.main.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "pinwall", withExtension: "html"),
           let html = try? Data(contentsOf: src) {
            try? html.write(to: dir.appendingPathComponent("pinwall.html"), options: .atomic)
        }
        let settings = WallSettings.load()
        let pins = PinStore.load()
        let cfg = "window.PINWALL_CONFIG = "
            + settings.configJSON(gallery: false, skeleton: settings.connected, app: false, reload: true)
            + ";\n"
        try? cfg.data(using: .utf8)?.write(to: dir.appendingPathComponent("settings.js"), options: .atomic)
        let pjs = "window.PINS = " + PinStore.pinsJSON(pins) + ";\n"
        try? pjs.data(using: .utf8)?.write(to: dir.appendingPathComponent("pins.js"), options: .atomic)
        // where the saver's "Options…" button finds the app (UserDefaults is
        // container-isolated in the appex, so this travels as a file too)
        try? Bundle.main.bundlePath.data(using: .utf8)?
            .write(to: dir.appendingPathComponent("apppath.txt"), options: .atomic)
    }
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

    public init(speed: Double, fade: Double, rise: Double, stagger: Double,
                columns: Double, topBlur: Double, chroma: Double,
                clock: Bool, clockPos: String, clockSize: Double, clockDate: Bool,
                clockFont: String, clockWeight: Double, clockGlass: Bool, clockColor: String,
                chargerOnly: Bool, refreshMins: Double = 60, pinTarget: Double = 100,
                connected: Bool, source: String) {
        self.speed = speed; self.fade = fade; self.rise = rise; self.stagger = stagger
        self.columns = columns; self.topBlur = topBlur; self.chroma = chroma
        self.clock = clock; self.clockPos = clockPos; self.clockSize = clockSize; self.clockDate = clockDate
        self.clockFont = clockFont; self.clockWeight = clockWeight
        self.clockGlass = clockGlass; self.clockColor = clockColor
        self.chargerOnly = chargerOnly
        self.refreshMins = refreshMins; self.pinTarget = pinTarget
        self.connected = connected
        self.source = source
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
            source: d.string(forKey: "source") ?? FeedSource.feed)
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
        PinWall.publishSaverMirror()   // keep the screensaver's file mirror fresh
    }
    /// Object literal for injecting into the page as `window.PINWALL_CONFIG`.
    /// `app` = running inside PinWall.app (keep the cursor visible); the
    /// screensaver passes false so the cursor stays hidden while it's showing.
    public func configJSON(gallery: Bool, skeleton: Bool, app: Bool,
                           hideWall: Bool = false, reload: Bool = false) -> String {
        "{ \"speed\": \(speed), \"fade\": \(fade), \"rise\": \(rise), \"stagger\": \(stagger), " +
        "\"columns\": \(columns), \"clock\": \(clock), \"clockPos\": \"\(clockPos)\", " +
        "\"clockSize\": \(clockSize), \"clockDate\": \(clockDate), " +
        "\"clockFont\": \"\(clockFont)\", \"clockWeight\": \(clockWeight), " +
        "\"clockGlass\": \(clockGlass), \"clockColor\": \"\(clockColor)\", " +
        "\"gallery\": \(gallery), \"skeleton\": \(skeleton), \"app\": \(app), " +
        "\"hideWall\": \(hideWall), \"reload\": \(reload) }"
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
