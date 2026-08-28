import Foundation

/// Fetches WAWebABPropsConfigs from the public WhatsApp Web JS (same path as Cobalt
/// `tools/web/ab-props-codegen`). This is the **definition** catalogue (code ↔ name),
/// not the per-account assignment blob (that needs `<iq xmlns="abt">` after login).
enum WebABProps {
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    static let home = URL(string: "https://web.whatsapp.com/")!

    static func fetch(progress: @escaping (Double, String) -> Void) async throws -> [String: String] {
        progress(2, "Fetch: web.whatsapp.com…")
        let html = try await get(home)
        let urls = jsURLs(in: html)
        guard !urls.isEmpty else { throw EditorError.message("Sem JS no HTML do WhatsApp Web.") }
        progress(8, "Fetch: \(urls.count) bundles JS…")

        var merged: [String: String] = [:]
        var done = 0
        var idx = 0
        while idx < urls.count {
            if merged.count >= 80 { break }
            let end = min(idx + 8, urls.count)
            let batch = Array(urls[idx..<end])
            idx = end
            try await withThrowingTaskGroup(of: [String: String].self) { group in
                for url in batch {
                    group.addTask {
                        (try? await Self.get(url)).map(Self.parse) ?? [:]
                    }
                }
                for try await map in group {
                    done += 1
                    if map.count > merged.count {
                        merged = map
                    } else {
                        for (k, v) in map { merged[k] = v }
                    }
                    progress(8 + 90 * Double(done) / Double(max(urls.count, 1)),
                             "Fetch JS \(done)/\(urls.count) · \(merged.count) props")
                }
            }
            if merged.count >= 80 { break }
        }
        if merged.isEmpty {
            throw EditorError.message("ABPropConfigs não apareceu nos JS. Tenta de novo em Wi-Fi.")
        }
        progress(100, "Fetch OK · \(merged.count) props")
        return merged
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

    private static func get(_ url: URL) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://web.whatsapp.com/", forHTTPHeaderField: "Referer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw EditorError.message("HTTP \(http.statusCode) \(url.host ?? "")")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ js: String) -> [String: String] {
        var map: [String: String] = [:]
        if let blob = objectBlob(in: js) {
            fill(&map, from: blob)
        }
        if map.count < 40 {
            fill(&map, from: js)
        }
        return map
    }

    private static func objectBlob(in js: String) -> String? {
        guard let sent = js.range(of: ".ABPropConfigs=") else { return nil }
        let startLimit = js.index(sent.lowerBound, offsetBy: -400_000, limitedBy: js.startIndex) ?? js.startIndex
        var i = sent.lowerBound
        var objectStart: String.Index?
        while i > startLimit {
            if js[i] == "{" {
                let pre = js.index(i, offsetBy: -6, limitedBy: js.startIndex) ?? js.startIndex
                let slice = String(js[pre..<i])
                if slice.range(of: #"var \w="#, options: .regularExpression) != nil {
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
            let c = js[j]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return String(js[js.index(after: os)..<j])
                }
            }
            j = js.index(after: j)
        }
        return nil
    }

    private static func fill(_ map: inout [String: String], from blob: String) {
        let re = try! NSRegularExpression(
            pattern: #"([A-Za-z0-9_]+):\[(\d+),\"?(bool|int|float|string)\"?,"#
        )
        let ns = blob as NSString
        for m in re.matches(in: blob, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let code = ns.substring(with: m.range(at: 2))
            map[code] = name
        }
    }
}
