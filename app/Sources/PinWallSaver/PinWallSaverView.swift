import ScreenSaver
import WebKit

/// PinWall screensaver.
///
/// The system hosts third-party savers in the sandboxed legacyScreenSaver appex
/// (hot corner, idle, and the System Settings preview all use it). That sandbox
/// gives the appex its OWN container home — `NSHomeDirectory()`, UserDefaults,
/// and Application Support all resolve inside the container, so the saver can't
/// see the app's pins or settings there. It does, however, hold a read-only
/// exception for the whole disk plus network access.
///
/// So the app PUBLISHES the wall as plain files in the real home
/// (`~/Library/Application Support/PinWall/web/`: pinwall.html + pins.js +
/// settings.js) and this view loads that file URL directly — the exact pattern
/// the old WebViewScreenSaver setup used on this machine for months.
@objc(PinWallSaverView)
final class PinWallSaverView: ScreenSaverView, WKNavigationDelegate {
    private var web: WKWebView!
    private var loaded = false
    private var occlusionEnabled = true               // WKWebView default
    private var occlusionWatchdog: Timer?
    private var termTimes: [Date] = []                // recent WebContent kills
    private var heartbeatChecks = 0

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let web = WKWebView(frame: bounds, configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        web.wantsLayer = true
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .black }
        web.setValue(false, forKey: "drawsBackground")   // black view shows until paint
        web.navigationDelegate = self
        setOcclusionDetection(web, enabled: false)   // BEFORE addSubview, like WVSS
        addSubview(web)
        self.web = web
        // Belt-and-braces: legacyScreenSaver often never delivers stopAnimation,
        // so a lingering-but-hidden host would keep compositing forever (battery
        // leak). Re-enable occlusion detection whenever we're not actually shown.
        occlusionWatchdog = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, let web = self.web else { return }
            self.setOcclusionDetection(web, enabled: !self.isOnScreen)
        }
        slog("init \(Int(bounds.width))x\(Int(bounds.height)) preview=\(isPreview) home=\(NSHomeDirectory())")
    }

    private var isOnScreen: Bool { window != nil && (window?.isVisible ?? false) }

    /// THE fix that made WebViewScreenSaver work on Sonoma+ (this exact wall ran
    /// on it for months): the screensaver appex's remote-hosted window reports
    /// as OCCLUDED, so WebKit marks the page invisible and suspends rAF, timers
    /// AND the compositor — JS keeps running but nothing ever repaints (black).
    /// `_setWindowOcclusionDetectionEnabled:NO` makes WebKit treat the page as
    /// always-visible. We re-enable it in stopAnimation so a leaked host can't
    /// burn CPU animating an invisible wall (the old WVSS battery bug).
    private func setOcclusionDetection(_ webView: WKWebView, enabled: Bool) {
        if occlusionEnabled == enabled { return }   // no-op + no log spam when unchanged
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: sel) else { slog("occlusion SPI MISSING — relying on native assist"); return }
        typealias SetBoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void
        let imp = webView.method(for: sel)
        unsafeBitCast(imp, to: SetBoolIMP.self)(webView, sel, enabled)
        occlusionEnabled = enabled
        slog("occlusionDetection=\(enabled ? "on" : "OFF")")
    }

    private var usedFallback = false

    private func loadWall() {
        guard web != nil else { slog("loadWall: no webview"); return }
        // Preferred: the mirror the app published into the REAL home.
        let mirror = PinWall.saverWebDir.appendingPathComponent("pinwall.html")
        if !usedFallback, FileManager.default.fileExists(atPath: mirror.path) {
            slog("loadWall mirror=\(mirror.path)")
            web.loadFileURL(mirror, allowingReadAccessTo: mirror.deletingLastPathComponent())
            return
        }
        // Mirror missing (app never launched here / translocated) — fall back to
        // the bundled page. In the appex the container has no pins, so this shows
        // the SKELETON, never internet picsum images on someone's lock screen.
        slog("loadWall FALLBACK: bundled html (usedFallback=\(usedFallback))")
        loadBundled(skeleton: true)
    }

    /// Load the bundled page. skeleton:true = shimmer placeholder, no images and
    /// no network — used as the offline/not-set-up and kill-loop safe state.
    private func loadBundled(skeleton: Bool) {
        guard let web else { return }
        let b = Bundle(for: PinWallSaverView.self)
        guard let html = b.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
                ?? b.url(forResource: "pinwall", withExtension: "html"),
              let s = try? String(contentsOf: html, encoding: .utf8) else {
            slog("loadBundled: bundled html missing"); return
        }
        let js = pinwallBootstrapJS(pins: [], settings: WallSettings.load(),
                                    gallery: false, skeleton: skeleton, app: false)
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web.loadHTMLString(s, baseURL: nil)
    }

    override func startAnimation() {
        super.startAnimation()
        slog("startAnimation")
        if let web { setOcclusionDetection(web, enabled: false) }   // render while showing
        // Load once; macOS toggles start/stop rapidly around hot corners, and the
        // page pauses/resumes its own loop via pageshow/visibilitychange.
        if !loaded { loaded = true; loadWall() }
    }

    override func stopAnimation() {
        super.stopAnimation()
        slog("stopAnimation")
        // Never blank here — that caused stuck-black frames on quick start/stop.
        // Re-arm occlusion detection so WebKit can suspend the page when the
        // saver is genuinely off-screen (prevents the old WVSS battery leak).
        if let web { setOcclusionDetection(web, enabled: true) }
    }

    // lifecycle: re-enable occlusion detection the moment we're detached so a
    // hidden-but-alive host suspends the page instead of animating it forever.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let web { setOcclusionDetection(web, enabled: !isOnScreen) }
        slog("viewDidMoveToWindow window=\(window != nil ? "attached" : "DETACHED")")
    }
    deinit {
        occlusionWatchdog?.invalidate()
        NSLog("PinWallSaver: deinit")
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    private var assist = false

    override func animateOneFrame() {
        // Only when the page's own rAF loop was measured dead: drive its frame
        // loop from native at 30fps (scroll, reveal fallback, opacity audit,
        // clock repaint). When rAF is healthy this stays inert and the page
        // animates itself, exactly like the old WebViewScreenSaver setup.
        guard assist else { return }
        let now = Date().timeIntervalSince1970 * 1000
        web?.evaluateJavaScript("window.pinwallFrame && window.pinwallFrame(\(now));",
                                completionHandler: nil)
    }

    // MARK: - navigation diagnostics

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        slog("didFinish")
        // Fresh measurement per navigation (the page self-reloads hourly when the
        // feed changes) — don't let a stale assist verdict kill later blooms.
        assist = false; heartbeatRetried = false; heartbeatChecks = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkHeartbeat() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.probe() }
    }

    private var heartbeatRetried = false

    private func checkHeartbeat() {
        heartbeatChecks += 1
        guard heartbeatChecks <= 6 else { return }   // don't poll forever
        web.evaluateJavaScript("window.__beats || 0") { [weak self] result, error in
            guard let self else { return }
            if error != nil || result == nil {
                // page mid-navigation / just crashed — inconclusive, re-check
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkHeartbeat() }
                return
            }
            let beats = (result as? Int) ?? Int((result as? Double) ?? 0)
            if beats >= 5 {
                self.slog("rAF healthy (beats=\(beats)) — bloom entrance plays")
            } else if !self.heartbeatRetried {
                self.heartbeatRetried = true
                self.slog("rAF quiet (beats=\(beats)) — rechecking")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkHeartbeat() }
            } else {
                self.assist = true
                self.slog("rAF DEAD (beats=\(beats)) — enabling native assist")
                self.web.evaluateJavaScript("window.pinwallRevealNow && window.pinwallRevealNow();",
                                            completionHandler: nil)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }   // superseded load — benign
        slog("didFail: \(error.localizedDescription)")
        retryWithBundledPage()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        slog("didFailProvisional: \(error.localizedDescription)")
        retryWithBundledPage()
    }
    private func retryWithBundledPage() {
        guard !usedFallback else { return }
        usedFallback = true
        loadWall()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        termTimes.append(now)
        termTimes = termTimes.filter { now.timeIntervalSince($0) < 300 }   // last 5 min
        slog("WebContent TERMINATED (\(termTimes.count) in 5m)")
        if termTimes.count > 4 {
            // memory-pressure kill loop — stop reloading the heavy image wall and
            // sit on the lightweight, image-free skeleton instead.
            slog("kill loop — loading skeleton")
            loadBundled(skeleton: true)
            return
        }
        // exponential backoff, and give the real mirror another chance
        let delay = min(30.0, pow(2.0, Double(max(0, termTimes.count - 1))))
        usedFallback = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.loadWall() }
    }

    /// Sample the page a few seconds after load: are pins present, images
    /// loading, any JS errors? Lands in saver.log + the unified log.
    private func probe() {
        let js = "(function(){var im=document.querySelectorAll('#viewport img');var l=0,s=0;" +
            "for(var i=0;i<im.length;i++){if(im[i].complete&&im[i].naturalHeight>0)l++;" +
            "if(im[i].className.indexOf('show')>=0||im[i].className.indexOf('instant')>=0)s++;}" +
            "return JSON.stringify({rs:document.readyState,imgs:im.length,loaded:l,shown:s," +
            "body:document.body.className,pins:(window.PINS||[]).length," +
            "cfg:typeof window.PINWALL_CONFIG,err:window.__err||''});})()"
        web.evaluateJavaScript(js) { [weak self] result, error in
            self?.slog("probe: \((result as? String) ?? "nil") jsErr=\(error?.localizedDescription ?? "-")")
        }
    }

    // MARK: - "Options…" opens the PinWall app

    override var hasConfigureSheet: Bool { true }
    override var configureSheet: NSWindow? {
        // The host expects a real sheet when hasConfigureSheet is true —
        // returning nil is undefined behavior. Hand back a small panel that
        // opens the app and dismisses itself.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 84),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "PinWall"
        let label = NSTextField(labelWithString: "Opening PinWall settings…")
        label.frame = NSRect(x: 20, y: 32, width: 260, height: 20)
        label.alignment = .center
        panel.contentView?.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak panel] in
            self.openApp()
            guard let panel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) }
            else { panel.orderOut(nil) }
        }
        return panel
    }
    private func openApp() {
        // UserDefaults is container-isolated here, so the app's location travels
        // through the published file mirror instead.
        let pathFile = PinWall.saverWebDir.appendingPathComponent("apppath.txt")
        if let path = try? String(contentsOf: pathFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PinWall.appBundleID) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - logging (container file + unified log)

    private func slog(_ msg: String) {
        NSLog("PinWallSaver: %@", msg)
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [\(isPreview ? "preview" : "screen")] \(msg)\n"
        let url = PinWall.supportDir.appendingPathComponent("saver.log")
        // O_APPEND: atomic across the concurrent preview + screen processes that
        // share this container, so their lines don't clobber each other.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 256_000 {
            try? FileManager.default.removeItem(at: url)   // rotate
        }
        guard let data = line.data(using: .utf8) else { return }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd >= 0 { data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }; close(fd) }
    }
}
