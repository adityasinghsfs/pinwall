import SwiftUI
import WebKit

/// The live wall, hosted in a WKWebView. Used both for the in-app preview
/// (gallery = false) and the standalone Gallery window (gallery = true).
struct WallWebView: NSViewRepresentable {
    let gallery: Bool
    let settings: WallSettings
    /// Bump this to force a full reload (e.g. after a fresh harvest).
    var reloadToken: Int = 0
    /// Bump this to replay the entrance animation without reloading.
    var replayToken: Int = 0
    /// Bump this to play the wall OUT (unlink): tiles scroll off, then skeleton.
    var drainToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // stats bridge: the page posts {type:'stats', pins, secs} deltas
        cfg.userContentController.add(context.coordinator, name: "pinwall")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.wantsLayer = true
        if #available(macOS 12.0, *) { web.underPageBackgroundColor = .black }
        web.setValue(false, forKey: "drawsBackground")   // let the black page show through
        web.uiDelegate = context.coordinator
        context.coordinator.web = web
        context.coordinator.lastToken = reloadToken
        context.coordinator.lastReplayToken = replayToken
        load(web)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coord = context.coordinator
        if reloadToken != coord.lastToken {
            coord.lastToken = reloadToken
            coord.lastReplayToken = replayToken   // a reload already plays the entrance
            load(web)
            return
        }
        // Apply tuning + clock live, no reload — smooth slider dragging.
        let s = settings
        // Intro duration drives Bloom's fade/stagger and the radial/dots revealMs.
        let apply = "{speed:\(s.speed),fade:\(s.introMs * 0.30),rise:24,stagger:\(s.introMs * 0.55),revealMs:\(s.introMs),columns:\(s.columns),clock:\(s.clock),introStyle:'\(s.introStyle)',introOrigin:'\(s.introOrigin)',feedAngle:\(s.feedAngle)}"
        let clockCfg = "{pos:'\(s.clockPos)',size:\(s.clockSize),date:\(s.clockDate),font:'\(s.clockFont)',weight:\(s.clockWeight),glass:\(s.clockGlass),color:'\(s.clockColor)'}"
        let js = "window.pinwallApply && window.pinwallApply(\(apply));"
               + "window.pinwallClockConfig && window.pinwallClockConfig(\(clockCfg));"
        web.evaluateJavaScript(js, completionHandler: nil)
        // Replay the entrance animation on demand (the "Start" button).
        if replayToken != coord.lastReplayToken {
            coord.lastReplayToken = replayToken
            web.evaluateJavaScript("window.pinwallReplay && window.pinwallReplay();", completionHandler: nil)
        }
        // Unlink: play the wall out instead of cutting to the skeleton.
        if drainToken != coord.lastDrainToken {
            coord.lastDrainToken = drainToken
            web.evaluateJavaScript("window.pinwallDrain && window.pinwallDrain();", completionHandler: nil)
        }
    }

    private func load(_ web: WKWebView) {
        guard let html = Bundle.main.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "pinwall", withExtension: "html") else { return }
        let pins = PinStore.load()
        // Skeleton (not the public demo wall) whenever the user has a source set
        // up — Pinterest connected OR the iCloud tab — and the wall is empty.
        let skel = settings.connected || settings.provider == "icloud"
        let js = pinwallBootstrapJS(pins: pins, settings: settings,
                                    gallery: gallery, skeleton: skel, app: true)
        let user = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.addUserScript(user)
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var lastToken = 0
        var lastReplayToken = 0
        var lastDrainToken = 0
        // page → host: lifetime stats deltas (and tuner posts, which we ignore)
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pinwall", let d = message.body as? [String: Any],
                  (d["type"] as? String) == "stats" else { return }
            WallStats.add(pins: (d["pins"] as? Double) ?? 0, secs: (d["secs"] as? Double) ?? 0)
        }
        // In gallery mode, a pin click calls window.open — send it to the browser.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}

/// Standalone gallery window — the wall you can scroll back through by hand.
struct GalleryView: View {
    @State private var settings = WallSettings.load()
    var body: some View {
        WallWebView(gallery: true, settings: settings)
            .ignoresSafeArea()
            .background(Color.black)
    }
}
