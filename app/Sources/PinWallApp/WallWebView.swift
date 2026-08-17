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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
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
        let apply = "{speed:\(s.speed),fade:\(s.fade),rise:\(s.rise),stagger:\(s.stagger),columns:\(s.columns),clock:\(s.clock),introStyle:'\(s.introStyle)',introOrigin:'\(s.introOrigin)'}"
        let clockCfg = "{pos:'\(s.clockPos)',size:\(s.clockSize),date:\(s.clockDate),font:'\(s.clockFont)',weight:\(s.clockWeight),glass:\(s.clockGlass),color:'\(s.clockColor)'}"
        let js = "window.pinwallApply && window.pinwallApply(\(apply));"
               + "window.pinwallClockConfig && window.pinwallClockConfig(\(clockCfg));"
        web.evaluateJavaScript(js, completionHandler: nil)
        // Replay the entrance animation on demand (the "Start" button).
        if replayToken != coord.lastReplayToken {
            coord.lastReplayToken = replayToken
            web.evaluateJavaScript("window.pinwallReplay && window.pinwallReplay();", completionHandler: nil)
        }
    }

    private func load(_ web: WKWebView) {
        guard let html = Bundle.main.url(forResource: "pinwall", withExtension: "html", subdirectory: "web")
            ?? Bundle.main.url(forResource: "pinwall", withExtension: "html") else { return }
        let pins = PinStore.load()
        let js = pinwallBootstrapJS(pins: pins, settings: settings,
                                    gallery: gallery, skeleton: settings.connected, app: true)
        let user = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        web.configuration.userContentController.removeAllUserScripts()
        web.configuration.userContentController.addUserScript(user)
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKUIDelegate {
        weak var web: WKWebView?
        var lastToken = 0
        var lastReplayToken = 0
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
