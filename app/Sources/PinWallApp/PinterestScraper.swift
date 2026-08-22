import Foundation
import WebKit

/// Scrapes the logged-in Pinterest feed by driving a WKWebView — the native
/// equivalent of harvest_feed.py (same DOM logic, no Python/Playwright). Works
/// on any webview whose data store already holds the user's Pinterest cookies.
@MainActor
final class PinterestScraper: NSObject {
    static let minPins = 15   // fewer than this and we won't OVERWRITE a good wall

    private let web: WKWebView
    private var loadWaiter: LoadWaiter?

    init(web: WKWebView) { self.web = web }

    /// Returns the collected pins and whether the session is actually logged in.
    /// `loggedIn` is a POSITIVE auth signal (username resolves / no login CTA) —
    /// NOT "we found ≥15 images", because logged-out Pinterest also shows a big
    /// public grid. Callers must not overwrite a good wall unless loggedIn AND
    /// pins.count >= minPins.
    func run(sourceURL: URL = URL(string: "https://www.pinterest.com/")!,
             target: Int = 100, maxScrolls: Int = 50, needsLoad: Bool) async -> (pins: [Pin], loggedIn: Bool) {
        if needsLoad {
            await load(sourceURL)
            await sleep(4.0)
        }
        let auth = await authState()
        var seen = Set<String>()
        var pairs: [Pin] = []
        var stagnant = 0
        for _ in 0..<maxScrolls {
            let before = pairs.count
            for it in await scrapeOnce() {
                guard isPin(it.img) else { continue }
                let u = upsize(it.img)
                if seen.insert(u).inserted {
                    pairs.append(Pin(img: u, link: absLink(it.link)))
                }
            }
            if pairs.count >= target { break }
            // Stop when the source is EXHAUSTED: a board usually has far fewer
            // pins than the target, so without this the scrape grinds the full
            // maxScrolls (minutes) and times out the in-app refresh. Bail after
            // a few consecutive scrolls that surface no new pins.
            if pairs.count == before {
                stagnant += 1
                if stagnant >= 4 { break }
            } else {
                stagnant = 0
            }
            // human-ish scrolling: vary both distance and dwell time — fixed
            // 2200px/1.2s steps are as much a bot fingerprint as fixed intervals
            let dist = Int.random(in: 1600...2800)
            _ = await evalJS("window.scrollTo(0, (window.scrollY||0) + \(dist)); 1;")
            await sleep(Double.random(in: 0.8...1.9))
        }
        return (Array(pairs.prefix(target)), auth.loggedIn)
    }

    // MARK: - auth detection (positive signal, not image count)

    /// Best-effort login state + the logged-in username. Combines a session
    /// cookie, a resolvable profile link, and the absence of login CTAs so a
    /// logged-out public grid is not mistaken for a real feed, and a sparse but
    /// genuine feed is not mistaken for logged-out.
    func authState() async -> (loggedIn: Bool, username: String?) {
        let js = #"""
        (function(){
          var reserved = {pin:1,search:1,ideas:1,settings:1,news:1,today:1,login:1,signup:1,business:1,all:1};
          function findUser(){
            var sels=['[data-test-id="header-profile"] a[href^="/"]','[data-test-id="user-profile-link"]','div[data-test-id="header-menu"] a[href^="/"]'];
            for(var i=0;i<sels.length;i++){var a=document.querySelector(sels[i]);if(!a)continue;var m=(a.getAttribute('href')||'').match(/^\/([^\/]+)\/?$/);if(m&&m[1]&&m[1].charAt(0)!=='_'&&!reserved[m[1]])return m[1];}
            var links=document.querySelectorAll('a[href^="/"]');
            for(var j=0;j<links.length;j++){var mm=(links[j].getAttribute('href')||'').match(/^\/([^\/]+)\/?$/);if(mm&&mm[1]&&mm[1].charAt(0)!=='_'&&!reserved[mm[1]]&&(links[j].querySelector('img')||links[j].getAttribute('aria-label')))return mm[1];}
            try{var s=document.getElementById('__PWS_DATA__');var t=s?s.textContent:'';var mj=t.match(/"username"\s*:\s*"([^"]+)"/);if(mj&&mj[1])return mj[1];}catch(e){}
            return null;
          }
          var user=findUser();
          var loginCTA=document.querySelector('[data-test-id="simple-login-button"],[data-test-id="login-button"],[data-test-id="signup-button"],[data-test-id="unauth-actions"]');
          var onLoginPage=/^\/(login|signup)/.test(location.pathname||'');
          return { user: user, loggedIn: (!!user || (!loginCTA && !onLoginPage)) };
        })();
        """#
        if let d = await evalJS(js) as? [String: Any] {
            return ((d["loggedIn"] as? Bool) ?? false, d["user"] as? String)
        }
        return (false, nil)
    }

    // MARK: - discover the user's boards (best-effort) for the source dropdown

    func discoverBoards() async -> [Board] {
        await load(URL(string: "https://www.pinterest.com/")!)
        await sleep(3.0)
        guard let user = await authState().username, !user.isEmpty else {
            Harvester.log("discoverBoards: no username resolved — treating as logged out")
            return []
        }
        Harvester.log("discoverBoards: user=\(user)")

        // First choice: Pinterest's own BoardsResource API, fetched from inside
        // the logged-in page (cookies ride along). Gives structured boards with
        // an archived timestamp (filtered out) sorted by last-pinned — so the
        // newest boards appear and archived ones don't.
        let kick = """
        (function(){
          window.__pwBoards = null;
          var u = \(jsString(user));
          var data = { options: { username: u, field_set_key: 'profile_grid_item',
                                  sort: 'last_pinned_to', filter_stories: false }, context: {} };
          fetch('/resource/BoardsResource/get/?source_url=' + encodeURIComponent('/' + u + '/_saved/')
                + '&data=' + encodeURIComponent(JSON.stringify(data)),
                { credentials: 'include', headers: { 'Accept': 'application/json',
                                                     'X-Requested-With': 'XMLHttpRequest' } })
            .then(function(r){ return r.json(); })
            .then(function(j){
              var arr = (j && j.resource_response && j.resource_response.data) || [];
              window.__pwBoards = arr.map(function(b){
                return { name: b.name || '', url: b.url || '',
                         archived: !!b.archived_by_me_at };
              });
            })
            .catch(function(e){ window.__pwBoards = { err: String(e) }; });
          return 1;
        })();
        """
        _ = await evalJS(kick)
        for _ in 0..<16 {   // poll up to ~8s for the fetch to land
            await sleep(0.5)
            if let arr = await evalJS("window.__pwBoards") as? [[String: Any]] {
                let boards = arr.compactMap { d -> Board? in
                    guard let url = d["url"] as? String, !url.isEmpty,
                          (d["archived"] as? Bool) != true else { return nil }
                    let name = (d["name"] as? String) ?? ""
                    let full = url.hasPrefix("/") ? "https://www.pinterest.com" + url : url
                    return Board(name: name.isEmpty ? full : name, url: full)
                }
                if !boards.isEmpty {
                    Harvester.log("discoverBoards: API found=\(boards.count) (of \(arr.count) incl. archived)")
                    return boards
                }
                break   // API answered but empty — fall back to the DOM scrape
            }
            if let e = await evalJS("window.__pwBoards && window.__pwBoards.err") as? String {
                Harvester.log("discoverBoards: API error \(e) — falling back to DOM")
                break
            }
        }

        // Fallback: scrape the boards tab (/_saved/) + the page's JSON blob.
        await load(URL(string: "https://www.pinterest.com/\(user)/_saved/")!)
        await sleep(3.5)
        for _ in 0..<4 { _ = await evalJS("window.scrollTo(0,(window.scrollY||0)+1500);1;"); await sleep(0.8) }
        // Two extraction passes: anchor links (filtered by regex — never build the
        // selector by string concat, that broke once before) PLUS the __PWS_DATA__
        // JSON blob, which contains board URLs even when the grid is virtualised.
        let js = """
        (function(){
          var u = \(jsString(user));
          var reserved = {pins:1,boards:1,followers:1,following:1,tried:1,_saved:1,_created:1};
          var out = {};
          function add(slug, name){
            if (!slug || slug.charAt(0) === '_' || reserved[slug.toLowerCase()]) return;
            var full = 'https://www.pinterest.com/' + u + '/' + slug + '/';
            if (!out[full]) out[full] = (name || slug.replace(/[-_]+/g, ' ')).trim();
          }
          var re = new RegExp('^/' + u + '/([^/]+)/?$');
          Array.prototype.forEach.call(document.querySelectorAll('a[href^="/"]'), function(a){
            var m = (a.getAttribute('href') || '').match(re); if (!m) return;
            add(m[1], (a.getAttribute('aria-label') || a.textContent || '').trim());
          });
          try {
            var s = document.getElementById('__PWS_DATA__');
            if (s) {
              var rej = new RegExp('"/' + u + '/([a-zA-Z0-9%_\\\\-]+)/"', 'g'), mm;
              while ((mm = rej.exec(s.textContent)) !== null) {
                try { add(decodeURIComponent(mm[1]), null); } catch (e) { add(mm[1], null); }
              }
            }
          } catch (e) {}
          return Object.keys(out).map(function(k){ return { url: k, name: out[k] }; });
        })();
        """
        guard let arr = await evalJS(js) as? [[String: Any]] else {
            Harvester.log("discoverBoards: JS returned nothing")
            return []
        }
        let boards = arr.compactMap { d -> Board? in
            guard let url = d["url"] as? String else { return nil }
            let raw = (d["name"] as? String) ?? url
            return Board(name: raw.isEmpty ? url : raw.capitalized, url: url)
        }
        Harvester.log("discoverBoards: found=\(boards.count)")
        return boards
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

    /// Loads a URL and resolves when navigation finishes/fails OR after a hard
    /// timeout — so a hung Pinterest load (or a dead WebContent process) can
    /// never deadlock the connect window or the headless harvest.
    private func load(_ url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = OnceResumer(c)
            let waiter = LoadWaiter { once.fire() }
            loadWaiter = waiter
            web.navigationDelegate = waiter
            web.load(URLRequest(url: url))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { once.fire() }
        }
    }

    private func sleep(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }
}

/// Resumes a continuation at most once (main-thread only).
final class OnceResumer {
    private var cont: CheckedContinuation<Void, Never>?
    init(_ c: CheckedContinuation<Void, Never>) { cont = c }
    func fire() { cont?.resume(); cont = nil }
}

/// Resolves once the first navigation finishes/fails — or the content process dies.
final class LoadWaiter: NSObject, WKNavigationDelegate {
    private let done: () -> Void
    private var fired = false
    init(done: @escaping () -> Void) { self.done = done }
    private func fire() { if !fired { fired = true; done() } }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { fire() }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { fire() }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { fire() }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { fire() }
}
