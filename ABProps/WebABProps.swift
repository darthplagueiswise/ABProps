import Foundation
import UIKit
import WebKit

/// Fetch real do WhatsApp Web, no iPhone: WKWebView em modo desktop
/// (mesmo papel do Playwright no Cobalt). Sem fallback pra Cobalt/GitHub.
enum WebABProps {
    static let home = URL(string: "https://web.whatsapp.com/")!
    static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    static func fetch(progress: @escaping (Double, String) -> Void) async throws -> [String: String] {
        progress(4, "Abrindo WhatsApp Web (desktop)…")
        let html = try await DesktopPage.load(progress: progress)
        let urls = jsURLs(in: html)
        guard !urls.isEmpty else {
            throw EditorError.message("HTML sem bundles JS. O site ainda mandou a página mobile.")
        }
        progress(20, "Web OK · \(urls.count) JS · baixando…")

        var merged: [String: String] = [:]
        var done = 0
        var idx = 0
        while idx < urls.count, merged.count < 80 {
            let end = min(idx + 8, urls.count)
            let batch = Array(urls[idx..<end])
            idx = end
            try await withThrowingTaskGroup(of: [String: String].self) { group in
                for url in batch {
                    group.addTask { parseJS((try? await getJS(url)) ?? "") }
                }
                for try await map in group {
                    done += 1
                    for (k, v) in map { merged[k] = v }
                    progress(20 + 75 * Double(done) / Double(max(urls.count, 1)),
                             "JS \(done)/\(urls.count) · \(merged.count) props")
                }
            }
            if merged.count >= 80 { break }
        }
        if merged.isEmpty {
            throw EditorError.message("ABPropConfigs não veio nos JS. Tenta de novo no Wi-Fi.")
        }
        progress(100, "Fetch Web OK · \(merged.count) props")
        return merged
    }

    static func parseJS(_ js: String) -> [String: String] {
        var map: [String: String] = [:]
        if let blob = objectBlob(in: js) { fill(&map, from: blob) }
        if map.count < 40 { fill(&map, from: js) }
        return map
    }

    private static func jsURLs(in html: String) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        let patterns = [
            #"src":"(https:[^"]+)"#,
            #"src="(https://static\.whatsapp\.net/rsrc\.php/[^"]+)""#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                var s = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\/", with: "/")
                if s.contains(".css") { continue }
                if !(s.contains(".js") || s.contains("/rsrc.php/")) { continue }
                if seen.insert(s).inserted, let u = URL(string: s) { out.append(u) }
            }
        }
        return out
    }

    private static func getJS(_ url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue(chromeUA, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://web.whatsapp.com/", forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("script", forHTTPHeaderField: "Sec-Fetch-Dest")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.httpAdditionalHeaders = [
            "User-Agent": chromeUA,
            "Accept-Language": "en-US,en;q=0.9",
        ]
        return URLSession(configuration: c)
    }()

    private static func objectBlob(in js: String) -> String? {
        guard let sent = js.range(of: ".ABPropConfigs=") else { return nil }
        let startLimit = js.index(sent.lowerBound, offsetBy: -400_000, limitedBy: js.startIndex) ?? js.startIndex
        var i = sent.lowerBound
        var objectStart: String.Index?
        while i > startLimit {
            if js[i] == "{" {
                let pre = js.index(i, offsetBy: -6, limitedBy: js.startIndex) ?? js.startIndex
                if String(js[pre..<i]).range(of: #"var \w="#, options: .regularExpression) != nil {
                    objectStart = i
                    break
                }
            }
            i = js.index(before: i)
        }
        guard let os = objectStart else { return nil }
        var depth = 0
        var j = os
        while j < js.endIndex {
            if js[j] == "{" { depth += 1 }
            else if js[j] == "}" {
                depth -= 1
                if depth == 0 { return String(js[js.index(after: os)..<j]) }
            }
            j = js.index(after: j)
        }
        return nil
    }

    private static func fill(_ map: inout [String: String], from blob: String) {
        let re = try! NSRegularExpression(pattern: #"([A-Za-z0-9_]+):\[(\d+),\"?(bool|int|float|string)\"?,"#)
        let ns = blob as NSString
        for m in re.matches(in: blob, range: NSRange(location: 0, length: ns.length)) {
            map[ns.substring(with: m.range(at: 2))] = ns.substring(with: m.range(at: 1))
        }
    }
}

/// WKWebView desktop — o WhatsApp Web no iPhone redireciona mobile / devolve 400 no URLSession.
@MainActor
final class DesktopPage: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var settled = false

    static func load(progress: @escaping (Double, String) -> Void) async throws -> String {
        let loader = DesktopPage()
        return try await loader.run(progress: progress)
    }

    private func run(progress: @escaping (Double, String) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            config.defaultWebpagePreferences.preferredContentMode = .desktop
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
            wv.customUserAgent = WebABProps.chromeUA
            wv.navigationDelegate = self
            if #available(iOS 16.4, *) { wv.isInspectable = false }
            self.webView = wv
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                let win = scene.windows.first ?? scene.keyWindow
                wv.alpha = 0.01
                wv.isUserInteractionEnabled = false
                wv.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
                win?.addSubview(wv)
            }
            progress(8, "WKWebView desktop → web.whatsapp.com")
            var req = URLRequest(url: WebABProps.home, timeoutInterval: 35)
            req.setValue(WebABProps.chromeUA, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("1", forHTTPHeaderField: "Upgrade-Insecure-Requests")
            req.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
            req.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
            req.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
            wv.load(req)
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
                self?.fail(EditorError.message("Timeout no WhatsApp Web (40s)."))
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = .desktop
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, error in
            if let html = result as? String, html.count > 50_000 {
                self?.finish(html)
            } else if let error {
                self?.fail(error)
            } else {
                self?.fail(EditorError.message("Página pequena demais (\( (result as? String)?.count ?? 0 ) bytes) — ainda mobile."))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail(error)
    }

    private func finish(_ html: String) {
        guard !settled else { return }
        settled = true
        webView?.removeFromSuperview()
        continuation?.resume(returning: html)
        continuation = nil
    }

    private func fail(_ error: Error) {
        guard !settled else { return }
        settled = true
        webView?.removeFromSuperview()
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
