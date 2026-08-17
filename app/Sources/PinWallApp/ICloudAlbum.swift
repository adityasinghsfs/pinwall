import Foundation

/// Fetches photos from a PUBLIC iCloud Shared Album ("Public Website" link).
///
/// Uses Apple's shared-stream web API — the same one icloud.com's public album
/// page calls (`webstream` for the photo list, `webasseturls` for signed CDN
/// URLs). It's undocumented but stable for years and needs no login for public
/// albums. Flow:
///   1. token from the link:  icloud.com/sharedalbum/#B0abcd…  →  B0abcd…
///   2. POST {token}/sharedstreams/webstream  → photo list (330 = follow the
///      X-Apple-MMe-Host / body host redirect to the album's partition)
///   3. POST {token}/sharedstreams/webasseturls with the photoGuids
///      → checksum → {url_location, url_path} map → https URLs
enum ICloudAlbum {
    struct AlbumError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Extracts the album token from any form of the share link.
    /// Accepts: https://www.icloud.com/sharedalbum/#B0…, …/sharedalbum/B0…, or a bare token.
    static func token(from link: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.range(of: "#") {
            let t = String(s[hash.upperBound...]).split(separator: ";").first.map(String.init) ?? ""
            if !t.isEmpty { return t }
        }
        if let r = s.range(of: "/sharedalbum/") {
            let t = String(s[r.upperBound...]).split(separator: "/").first.map(String.init) ?? ""
            if !t.isEmpty && !t.hasPrefix("#") { return t }
        }
        // bare token: B0/A1-prefixed base62-ish, no scheme, no slashes
        if !s.contains("/") && !s.contains(" ") && s.count >= 8 && (s.hasPrefix("A") || s.hasPrefix("B")) { return s }
        return nil
    }

    /// Apple partitions albums across pXX hosts; the first request goes to a
    /// host derived from the token, and a 330 response redirects to the right one.
    private static func seedHost(for token: String) -> String {
        // Standard client-side derivation: base-62 value of the char after the
        // leading "A"/"B" determines the partition; fall back to p01.
        func b62(_ c: Character) -> Int? {
            if let d = c.wholeNumberValue, c.isNumber { return d }
            if c.isUppercase, let a = c.asciiValue { return Int(a) - 65 + 10 }
            if c.isLowercase, let a = c.asciiValue { return Int(a) - 97 + 36 }
            return nil
        }
        guard token.count >= 2 else { return "p01-sharedstreams.icloud.com" }
        let second = token[token.index(token.startIndex, offsetBy: 1)]
        let p = (b62(second).map { $0 % 40 } ?? 1) + 1
        return String(format: "p%02d-sharedstreams.icloud.com", max(1, p))
    }

    private static func post(_ url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.icloud.com", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (Macintosh) PinWall", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AlbumError(message: "No HTTP response") }
        return (data, http)
    }

    /// Fetches the album's photos as Pins (largest derivative per photo).
    /// Videos are skipped. Order: newest first, capped at `limit`.
    static func fetch(link: String, limit: Int = 300) async throws -> [Pin] {
        guard let tok = token(from: link) else {
            throw AlbumError(message: "That doesn't look like an iCloud Shared Album link")
        }
        var host = seedHost(for: tok)

        // -- webstream (photo list), following one partition redirect ----------
        func webstream(_ host: String) async throws -> (Data, HTTPURLResponse) {
            try await post(URL(string: "https://\(host)/\(tok)/sharedstreams/webstream")!,
                           body: ["streamCtag": NSNull()])
        }
        var (data, http) = try await webstream(host)
        if http.statusCode == 330 {
            // redirect target comes in the JSON body (X-Apple-MMe-Host) — use it
            if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let h = j["X-Apple-MMe-Host"] as? String {
                host = h
                (data, http) = try await webstream(host)
            }
        }
        guard http.statusCode == 200 else {
            throw AlbumError(message: "Album fetch failed (HTTP \(http.statusCode)) — is the link a public album?")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = root["photos"] as? [[String: Any]], !photos.isEmpty else {
            throw AlbumError(message: "Album is empty or the response was unexpected")
        }

        // newest first, images only, capped
        struct Item { let guid: String; let checksum: String }
        var items: [Item] = []
        for p in photos.reversed() {
            guard let guid = p["photoGuid"] as? String,
                  let derivatives = p["derivatives"] as? [String: [String: Any]], !derivatives.isEmpty else { continue }
            if let type = p["mediaAssetType"] as? String, type.lowercased() == "video" { continue }
            // largest derivative = max numeric key (keys are pixel sizes as strings)
            let best = derivatives.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            guard let checksum = best?.value["checksum"] as? String else { continue }
            items.append(Item(guid: guid, checksum: checksum))
            if items.count >= limit { break }
        }
        guard !items.isEmpty else { throw AlbumError(message: "No photos found in that album") }

        // -- webasseturls (signed CDN urls), batched ---------------------------
        var urlByChecksum: [String: String] = [:]
        for batch in stride(from: 0, to: items.count, by: 25).map({ Array(items[$0..<min($0 + 25, items.count)]) }) {
            let (adata, ahttp) = try await post(
                URL(string: "https://\(host)/\(tok)/sharedstreams/webasseturls")!,
                body: ["photoGuids": batch.map { $0.guid }])
            guard ahttp.statusCode == 200,
                  let aroot = try? JSONSerialization.jsonObject(with: adata) as? [String: Any],
                  let assets = aroot["items"] as? [String: [String: Any]] else { continue }
            for (checksum, loc) in assets {
                if let l = loc["url_location"] as? String, let path = loc["url_path"] as? String {
                    urlByChecksum[checksum] = "https://\(l)\(path)"
                }
            }
        }

        let pins = items.compactMap { it -> Pin? in
            guard let u = urlByChecksum[it.checksum] else { return nil }
            return Pin(img: u, link: "")
        }
        guard !pins.isEmpty else { throw AlbumError(message: "Couldn't resolve photo URLs for that album") }
        return pins
    }
}
