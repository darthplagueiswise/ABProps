import Foundation

indirect enum PlistValue {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case date(Double)
    case data(Data)
    case str(String)
    case arr([PlistValue])
    case dict([(String, PlistValue)])
    case nested(PlistValue)

    var dictPairs: [(String, PlistValue)]? {
        if case .dict(let p) = self { return p }
        return nil
    }

    func get(_ key: String) -> PlistValue? {
        guard let pairs = dictPairs else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }

    func set(_ key: String, _ value: PlistValue) -> PlistValue {
        guard var pairs = dictPairs else { return self }
        if let i = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[i] = (key, value)
        } else {
            pairs.append((key, value))
        }
        return .dict(pairs)
    }

    func unwrapped() -> PlistValue {
        switch self {
        case .data(let d) where PlistCodec.isBplist(d):
            if let inner = try? PlistValue.parse(d) { return .nested(inner.unwrapped()) }
            return self
        case .arr(let a): return .arr(a.map { $0.unwrapped() })
        case .dict(let p): return .dict(p.map { ($0.0, $0.1.unwrapped()) })
        default: return self
        }
    }

    func wrapped() -> PlistValue {
        switch self {
        case .nested(let v):
            let bytes = (try? v.wrapped().serialize()) ?? Data()
            return .data(bytes)
        case .arr(let a): return .arr(a.map { $0.wrapped() })
        case .dict(let p): return .dict(p.map { ($0.0, $0.1.wrapped()) })
        default: return self
        }
    }

    func flagValue(store: String, code: String) -> String? {
        guard case .nested(let map) = get(store), case .dict = map else { return nil }
        return Self.scalar(map.get(code).flatMap { $0.get("value") })
    }

    func settingFlag(store: String, code: String, value: String) -> PlistValue {
        var map: PlistValue
        if case .nested(let inner) = get(store), case .dict = inner {
            map = inner
        } else if case .dict = get(store) {
            map = get(store)!
        } else {
            map = .dict([])
        }
        var entry = map.get(code) ?? .dict([("value", .str(value))])
        entry = entry.set("value", .str(value))
        return set(store, .nested(map.set(code, entry)))
    }

    static func scalar(_ v: PlistValue?) -> String? {
        switch v {
        case .str(let s): return s
        case .int(let n): return String(n)
        case .real(let n): return String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    static func parse(_ data: Data) throws -> PlistValue {
        try PlistCodec.parse(data)
    }

    func serialize() throws -> Data {
        try PlistCodec.serialize(self)
    }

    func preserving(live: PlistValue) -> PlistValue {
        guard case .dict(let origPairs) = self, case .dict(let livePairs) = live else {
            return live.wrapped()
        }
        var seen = Set<String>()
        var out: [(String, PlistValue)] = []
        for (k, orig) in origPairs {
            seen.insert(k)
            if let liveV = live.get(k) {
                out.append((k, Self.preserved(orig: orig, live: liveV)))
            } else {
                out.append((k, orig))
            }
        }
        for (k, liveV) in livePairs where !seen.contains(k) {
            out.append((k, liveV.wrapped()))
        }
        return .dict(out)
    }

    private static func preserved(orig: PlistValue, live: PlistValue) -> PlistValue {
        if case .data(let d) = orig, PlistCodec.isBplist(d), case .nested(let inner) = live {
            if let parsed = try? PlistValue.parse(d).unwrapped(), equal(parsed, inner) {
                return orig
            }
            if let bytes = try? inner.serialize() { return .data(bytes) }
        }
        if case .nested(let inner) = live, let bytes = try? inner.serialize() {
            return .data(bytes)
        }
        return equal(orig.unwrapped(), live) ? orig : live.wrapped()
    }

    static func equal(_ a: PlistValue, _ b: PlistValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.real(let x), .real(let y)): return x == y
        case (.date(let x), .date(let y)): return x == y
        case (.str(let x), .str(let y)): return x == y
        case (.data(let x), .data(let y)): return x == y
        case (.arr(let x), .arr(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.dict(let x), .dict(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && equal($0.1, $1.1) }
        case (.nested(let x), .nested(let y)): return equal(x, y)
        default: return false
        }
    }
}

struct FlagRow: Identifiable {
    var id: String { "\(storeKey):\(code)" }
    let storeKey: String
    let code: String
    let value: String
    let overlay: Bool
    let layer: String
}

struct Bucket: Identifiable {
    enum Kind { case flags, meta }
    let id: String
    let title: String
    let kind: Kind
    let storeKey: String
    let flags: [FlagRow]
}

struct Catalog {
    var root: PlistValue
    var original: PlistValue
    var originalRaw: PlistValue
    var originalBytes: Data?
    var fileName: String
    var buckets: [Bucket]

    var flagCount: Int { buckets.reduce(0) { $0 + $1.flags.count } }

    func changedCount(live: PlistValue) -> Int {
        var n = 0
        for b in buckets where b.kind == .flags {
            for r in b.flags {
                let a = original.flagValue(store: b.storeKey, code: r.code)
                let c = live.flagValue(store: b.storeKey, code: r.code)
                if a != c { n += 1 }
            }
        }
        return n
    }

    static func build(root: PlistValue, fileName: String) -> Catalog {
        guard case .dict(let pairs) = root else {
            return Catalog(root: root, original: root, originalRaw: root, originalBytes: nil, fileName: fileName, buckets: [])
        }
        var buckets: [Bucket] = []
        for (key, value) in pairs {
            let inner: PlistValue = {
                if case .nested(let v) = value { return v }
                return value
            }()
            if isFlagMap(inner) {
                buckets.append(Bucket(
                    id: key,
                    title: title(key),
                    kind: .flags,
                    storeKey: key,
                    flags: flags(store: key, map: inner)
                ))
            }
        }
        buckets.sort { weight($0.storeKey) < weight($1.storeKey) }
        return Catalog(root: root, original: root, originalRaw: root, originalBytes: nil, fileName: fileName, buckets: buckets)
    }

    static func isFlagMap(_ v: PlistValue) -> Bool {
        guard case .dict(let p) = v, !p.isEmpty else { return false }
        let sample = p.prefix(48)
        var ok = 0
        for (_, val) in sample {
            if case .dict = val, val.get("value") != nil { ok += 1 }
        }
        return Double(ok) / Double(sample.count) >= 0.75
    }

    static func flags(store: String, map: PlistValue) -> [FlagRow] {
        guard case .dict(let p) = map else { return [] }
        var rows: [FlagRow] = []
        for (code, entry) in p {
            guard case .dict = entry else { continue }
            rows.append(FlagRow(
                storeKey: store,
                code: code,
                value: PlistValue.scalar(entry.get("value")) ?? "",
                overlay: store.hasPrefix("gabp.o") && store.contains("@g.us"),
                layer: layer(store)
            ))
        }
        rows.sort { (Int($0.code) ?? 0) < (Int($1.code) ?? 0) }
        return rows
    }

    static func layer(_ key: String) -> String {
        if key.hasPrefix("gabp.o"), key.contains("@g.us"), key.hasSuffix("p") { return "overlay" }
        if key.hasPrefix("gabp.ofrep"), key.hasSuffix("p") { return "ofrep" }
        if key.hasPrefix("abp."), key.hasSuffix("p") { return "personal" }
        return "other"
    }

    static func title(_ key: String) -> String {
        if key.hasPrefix("abp.pnone"), key.hasSuffix("p") { return "Pessoal" }
        if key.hasPrefix("gabp.ofrep"), key.hasSuffix("p") { return "Grupo base (ofrep)" }
        if key.hasPrefix("gabp.o"), key.contains("@g.us"), key.hasSuffix("p") { return "Override de grupo" }
        if key.hasPrefix("abp.") { return "ABP" }
        if key.hasPrefix("gabp.") { return "Grupo" }
        return key
    }

    static func weight(_ key: String) -> Int {
        if key.hasPrefix("abp.pnone"), key.hasSuffix("p") { return 0 }
        if key.hasPrefix("abp.") { return 1 }
        if key.hasPrefix("gabp.ofrep"), key.hasSuffix("p") { return 2 }
        return 3
    }
}
