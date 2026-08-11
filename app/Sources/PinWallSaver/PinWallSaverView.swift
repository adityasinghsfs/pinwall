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
        slog("init \(Int(bounds.width))x\(Int(bounds.height)) preview=\(isPreview) home=\(NSHomeDirectory())")
    }

    /// THE fix that made WebViewScreenSaver work on Sonoma+ (this exact wall ran
    /// on it for months): the screensaver appex's remote-hosted window reports
    /// as OCCLUDED, so WebKit marks the page invisible and suspends rAF, timers
    /// AND the compositor — JS keeps running but nothing ever repaints (black).
    /// `_setWindowOcclusionDetectionEnabled:NO` makes WebKit treat the page as
    /// always-visible. We re-enable it in stopAnimation so a leaked host can't
    /// burn CPU animating an invisible wall (the old WVSS battery bug).
    private func setOcclusionDetection(_ webView: WKWebView, enabled: Bool) {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard webView.responds(to: sel) else { slog("occlusion SPI MISSING — relying on native assist"); return }
        typealias SetBoolIMP = @convention(c) (AnyObject, Selector, Bool) -> Void
        let imp = webView.method(for: sel)
        unsafeBitCast(imp, to: SetBoolIMP.self)(webView, sel, enabled)
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
        // Mirror missing (app never launched on this account) or its load
        // failed — fall back to the bundled page; it shows the demo wall.
        slog("loadWall FALLBACK: using bundled html (usedFallback=\(usedFallback))")
        let b = Bundle(for: PinWallSaverView.self)
        guard let html = b.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
                ?? b.url(forResource: "pinwall", withExtension: "html"),
              let s = try? String(contentsOf: html, encoding: .utf8) else {
            slog("loadWall: bundled html missing"); return
        }
        let js = pinwallBootstrapJS(pins: PinStore.load(), settings: WallSettings.load(),
                                    gallery: false, skeleton: false, app: false)
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

    // lifecycle diagnostics: WHO is tearing us down, and when
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        slog("viewDidMoveToWindow window=\(window != nil ? "attached" : "DETACHED")")
    }
    deinit {
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
        // Give the page's own rAF loop a moment, then measure it. If it beats,
        // do NOTHING — the original bottom-bloom entrance plays exactly like the
        // old WebViewScreenSaver setup. Only a dead loop gets native assistance.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.checkHeartbeat() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.probe() }
    }

    private var heartbeatRetried = false

    private func checkHeartbeat() {
        web.evaluateJavaScript("window.__beats || 0") { [weak self] result, _ in
            guard let self else { return }
            let beats = (result as? Int) ?? Int((result as? Double) ?? 0)
            if beats >= 5 {
                self.slog("rAF healthy (beats=\(beats)) — no assist, bloom entrance plays")
            } else if !self.heartbeatRetried {
                // The window may still be fading in — rAF can start late. Don't
                // steal the bloom with assist on a premature verdict.
                self.heartbeatRetried = true
                self.slog("rAF quiet (beats=\(beats)) — rechecking in 3s")
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
        slog("didFail: \(error.localizedDescription)")
        retryWithBundledPage()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        slog("didFailProvisional: \(error.localizedDescription)")
        retryWithBundledPage()
    }
    private func retryWithBundledPage() {
        guard !usedFallback else { return }
        usedFallback = true
        loadWall()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reload NOW — startAnimation won't fire again mid-session, and a dead
        // WebContent process would otherwise mean black until dismissal.
        slog("WebContent TERMINATED — reloading")
        loadWall()
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
        guard let data = line.data(using: .utf8) else { return }
        // throwing FileHandle APIs only — the legacy ones raise ObjC exceptions
        // that would crash the whole screensaver host on an I/O error
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
