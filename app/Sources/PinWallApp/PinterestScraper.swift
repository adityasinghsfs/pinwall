import Foundation
import WebKit

/// Scrapes the logged-in Pinterest feed by driving a WKWebView — the native
/// equivalent of harvest_feed.py (same DOM logic, no Python/Playwright). Works
/// on any webview whose data store already holds the user's Pinterest cookies.
@MainActor
final class PinterestScraper: NSObject {
    static let minPins = 15   // below this we assume logged-out/failed and don't overwrite

    private let web: WKWebView
    private var loadWaiter: LoadWaiter?

    init(web: WKWebView) { self.web = web }

    /// Returns the collected pins and whether we look logged in (enough pins).
    func run(sourceURL: URL = URL(string: "https://www.pinterest.com/")!,
             target: Int = 100, maxScrolls: Int = 50, needsLoad: Bool) async -> (pins: [Pin], loggedIn: Bool) {
        if needsLoad {
            await load(sourceURL)
            await sleep(4.0)
        }
        var seen = Set<String>()
        var pairs: [Pin] = []
        for _ in 0..<maxScrolls {
            for it in await scrapeOnce() {
                guard isPin(it.img) else { continue }
                let u = upsize(it.img)
                if seen.insert(u).inserted {
                    pairs.append(Pin(img: u, link: absLink(it.link)))
                }
            }
            if pairs.count >= target { break }
            // human-ish scrolling: vary both distance and dwell time — fixed
            // 2200px/1.2s steps are as much a bot fingerprint as fixed intervals
            let dist = Int.random(in: 1600...2800)
            _ = await evalJS("window.scrollTo(0, (window.scrollY||0) + \(dist)); 1;")
            await sleep(Double.random(in: 0.8...1.9))
        }
        return (Array(pairs.prefix(target)), pairs.count >= Self.minPins)
    }

    // MARK: - discover the user's boards (best-effort) for the source dropdown

    func discoverBoards() async -> [Board] {
        await load(URL(string: "https://www.pinterest.com/")!)
        await sleep(3.0)
        guard let user = await currentUsername(), !user.isEmpty else { return [] }
        await load(URL(string: "https://www.pinterest.com/\(user)/_created/")!)
        await sleep(3.0)
        for _ in 0..<4 { _ = await evalJS("window.scrollTo(0,(window.scrollY||0)+1500);1;"); await sleep(0.8) }
        let js = """
        (function(){
          var u = \(jsString(user));
          var re = new RegExp('^/' + u + '/([^/]+)/?$');
          var out = {};
          Array.prototype.forEach.call(document.querySelectorAll('a[href^="/"+u+"/"]'), function(a){
            var href = a.getAttribute('href') || '';
            var m = href.match(re); if (!m) return;
            var slug = m[1];
            if (slug.charAt(0) === '_' || ['pins','boards','followers','following'].indexOf(slug) >= 0) return;
            var name = (a.getAttribute('aria-label') || a.textContent || slug).trim();
            var full = 'https://www.pinterest.com/' + u + '/' + slug + '/';
            if (!out[full]) out[full] = name || slug;
          });
          return Object.keys(out).map(function(k){ return { url: k, name: out[k] }; });
        })();
        """
        guard let arr = await evalJS(js) as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard let url = d["url"] as? String else { return nil }
            return Board(name: (d["name"] as? String) ?? url, url: url)
        }
    }

    /// Best-effort logged-in username from the profile/avatar link in the header.
    private func currentUsername() async -> String? {
        let js = """
        (function(){
          var reserved = {pin:1,search:1,ideas:1,settings:1,news:1,today:1,login:1,business:1,all:1,'_':1};
          var sels = ['[data-test-id="header-profile"] a[href^="/"]',
                      '[data-test-id="user-profile-link"]',
                      'div[data-test-id="header-menu"] a[href^="/"]'];
          for (var i=0;i<sels.length;i++){
            var a = document.querySelector(sels[i]); if(!a) continue;
            var m = (a.getAttribute('href')||'').match(/^\\/([^\\/]+)\\/?$/);
            if (m && m[1] && m[1].charAt(0)!=='_' && !reserved[m[1]]) return m[1];
          }
          var links = document.querySelectorAll('a[href^="/"]');
          for (var j=0;j<links.length;j++){
            var mm = (links[j].getAttribute('href')||'').match(/^\\/([^\\/]+)\\/?$/);
            if (mm && mm[1] && mm[1].charAt(0)!=='_' && !reserved[mm[1]] &&
                (links[j].querySelector('img') || links[j].getAttribute('aria-label'))) return mm[1];
          }
          // fall back to the embedded page JSON (Pinterest ships __PWS_DATA__)
          try {
            var s = document.getElementById('__PWS_DATA__');
            var txt = s ? s.textContent : document.documentElement.innerHTML;
            var m = txt.match(/"username"\\s*:\\s*"([^"]+)"/);
            if (m && m[1]) return m[1];
          } catch (e) {}
          return null;
        })();
        """
        return await evalJS(js) as? String
    }

    private func jsString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    // MARK: - scrape one pass over the DOM (mirrors harvest_feed.py's eval)

    private func scrapeOnce() async -> [(img: String, link: String)] {
        let js = """
        (function(){ return Array.prototype.map.call(document.querySelectorAll('img'), function(e){
          var ss = e.getAttribute('srcset'); var img = e.src || '';
          if (ss) { var p = ss.split(',').map(function(s){ return s.trim().split(' ')[0]; }); img = p[p.length-1]; }
          var a = e.closest('a[href*="/pin/"]');
          return { img: img, link: a ? a.getAttribute('href') : '' };
        }); })();
        """
        guard let arr = await evalJS(js) as? [[String: Any]] else { return [] }
        return arr.map { (($0["img"] as? String) ?? "", ($0["link"] as? String) ?? "") }
    }

    // MARK: - filters ported from harvest_feed.py

    private func isPin(_ src: String) -> Bool {
        guard src.contains("i.pinimg.com") else { return false }
        if src.contains("/avatars/") || src.contains("/user/") || src.contains("_RS") { return false }
        if let re = try? NSRegularExpression(pattern: "/(\\d+)x"),
           let m = re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
           let r = Range(m.range(at: 1), in: src),
           let n = Int(src[r]), n < 200 { return false }
        return true
    }

    private func upsize(_ u: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "/\\d+x\\d*/") else { return u }
        return re.stringByReplacingMatches(in: u, range: NSRange(u.startIndex..., in: u), withTemplate: "/736x/")
    }

    private func absLink(_ href: String) -> String {
        if href.isEmpty { return "" }
        return href.hasPrefix("/") ? "https://www.pinterest.com" + href : href
    }

    // MARK: - async helpers over WKWebView

    private func evalJS(_ js: String) async -> Any? {
        await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            web.evaluateJavaScript(js) { r, _ in c.resume(returning: r) }
        }
    }

    private func load(_ url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let waiter = LoadWaiter { c.resume() }
            loadWaiter = waiter
            web.navigationDelegate = waiter
            web.load(URLRequest(url: url))
        }
    }

    private func sleep(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }
}

/// Resolves a continuation once the first navigation finishes (or fails).
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private let done: () -> Void
    private var fired = false
    init(done: @escaping () -> Void) { self.done = done }
    private func fire() { if !fired { fired = true; done() } }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { fire() }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fire() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fire() }
}
