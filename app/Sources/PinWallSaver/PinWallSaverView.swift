import ScreenSaver
import WebKit

/// PinWall screensaver: a ScreenSaverView that hosts a WKWebView running the
/// same wall as the app. Reads the harvested pins + tuning from the shared
/// store. Because it's a real ScreenSaverView, macOS starts/stops it with the
/// screen — no runaway host process like the old WebViewScreenSaver setup.
@objc(PinWallSaverView)
final class PinWallSaverView: ScreenSaverView {
    private var web: WKWebView!

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

        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.black.cgColor
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .black }
        // transparent so our black view shows through until the page paints
        // (avoids WebKit's default gray flash inside the screensaver host)
        web.setValue(false, forKey: "drawsBackground")
        addSubview(web)
        self.web = web
    }

    private func bundleURL() -> URL? {
        let b = Bundle(for: PinWallSaverView.self)
        return b.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
            ?? b.url(forResource: "pinwall", withExtension: "html")
    }

    private func loadWall() {
        // Load the HTML as a STRING rather than a file URL. Inside the sandboxed
        // screensaver host, WebKit's separate content process often can't get the
        // file-read sandbox extension from loadFileURL, so the page never paints
        // (black view -> gray webview). loadHTMLString sidesteps that entirely;
        // the pin images still load over the network.
        guard let html = bundleURL(),
              let htmlString = try? String(contentsOf: html, encoding: .utf8) else { return }
        let settings = WallSettings.load()
        let pins = PinStore.load()
        // logged in but no pins yet -> skeleton; otherwise the page falls back to a demo wall
        let js = pinwallBootstrapJS(pins: pins, settings: settings,
                                    gallery: false, skeleton: settings.connected, app: false)
        let user = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.addUserScript(user)
        web.loadHTMLString(htmlString, baseURL: nil)
    }

    override func startAnimation() {
        super.startAnimation()
        // Always show the wall. (Battery power-saving is handled by skipping the
        // feed refresh on battery, not by hiding the screensaver — trying to
        // sleep the display from the sandboxed saver isn't reliable.)
        loadWall()
    }

    override func stopAnimation() {
        super.stopAnimation()
        // Blank the page so WebKit can't keep compositing after we leave screen.
        web.loadHTMLString("<html><body style='background:#000;margin:0'></body></html>", baseURL: nil)
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    // WKWebView animates itself via requestAnimationFrame; nothing to do per tick.
    override func animateOneFrame() {}

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
