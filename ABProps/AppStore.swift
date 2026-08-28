import Foundation
import Observation
import UniformTypeIdentifiers
import UIKit

enum AppScreen: Hashable {
    case home
    case flags
    case mobileConfig
}

@Observable
final class AppStore {
    var screen: AppScreen = .home
    var catalog: Catalog?
    var liveRoot: PlistValue?
    var query = ""
    var onlyNamed = false
    var onlyUnnamed = false
    var onlyInject = false
    var topic: FlagTopic?
    var customCode = ""
    var customName = ""
    var customValue = "1"
    var names: [String: String] = [:]
    var types: [String: FlagKind] = [:]
    var status = "Aguardando arquivos"
    var disasmStatus = "Capstone ARM64 · parado"
    var disasmPct: Double = 0
    var busy = false
    var error: String?
    var toast: String?
    var plistName = ""
    var namedCount = 0
    var stubCount = 0

    var mcConfigs: [MCConfig] = []
    var mcQuery = ""
    var mcSelected: Set<String> = []
    var mcValues: [String: String] = [:]
    var mcMapLoaded = false
    var mcNamesLoaded = 0

    var lastFetchedJSON: Data?
    var fetched = false

    init() { loadBundledNames() }

    var dirtyCount: Int {
        guard let catalog, let liveRoot else { return 0 }
        var n = catalog.changedCount(live: liveRoot)
        for row in allFlags where row.layer == "inject" {
            let live = liveRoot.flagValue(store: row.storeKey, code: row.code) ?? row.value
            if live != row.value { n += 1 }
        }
        return n
    }

    var allFlags: [FlagRow] {
        var best: [String: FlagRow] = [:]
        if let catalog {
            let order = catalog.buckets.filter { $0.kind == .flags }.sorted { Catalog.weight($0.storeKey) < Catalog.weight($1.storeKey) }
            for b in order {
                for r in b.flags { best[r.code] = r }
            }
        }
        let storeKey = personalStore
        for (code, _) in names where best[code] == nil {
            best[code] = FlagRow(
                storeKey: storeKey,
                code: code,
                value: "0",
                overlay: false,
                layer: "inject"
            )
        }
        return best.values.sorted { (Int($0.code) ?? 0) < (Int($1.code) ?? 0) }
    }

    var personalStore: String {
        catalog?.buckets.first(where: { $0.storeKey.hasPrefix("abp.") && $0.storeKey.hasSuffix("p") })?.storeKey
            ?? "abp.pnonep"
    }

    var namedInPlist: Int {
        guard catalog != nil else { return 0 }
        let codes = Set(catalog!.buckets.filter { $0.kind == .flags }.flatMap { $0.flags.map(\.code) })
        return names.keys.filter { codes.contains($0) }.count
    }

    var injectCount: Int {
        max(0, names.count - namedInPlist)
    }

    func loadPlist(_ data: Data, name: String) throws {
        let raw = try PlistValue.parse(data)
        let parsed = raw.unwrapped()
        var next = Catalog.build(root: parsed, fileName: name)
        next.originalRaw = raw
        next.originalBytes = data
        if next.buckets.isEmpty {
            throw EditorError.message("Sem chaves abp./gabp. neste plist.")
        }
        catalog = next
        liveRoot = next.root
        plistName = name
        error = nil
        ping("Plist: \(next.flagCount) flags · \(namedInPlist) com nome · \(injectCount) só no framework")
        status = "\(name) · \(next.flagCount) flags · \(namedCount) nomes"
    }

    func loadFramework(_ data: Data) {
        busy = true
        disasmPct = 2
        disasmStatus = "Capstone: desmontando ARM64…"
        status = "Capstone: desmontando ARM64…"
        ping("Capstone iniciado · \(data.count / 1_000_000) MB")
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try MachOExtractor.extract(data) { pct, msg in
                    DispatchQueue.main.async {
                        self.disasmPct = pct
                        self.status = msg
                    }
                }
                DispatchQueue.main.async {
                    for (code, name) in result.byCode { self.names[code] = name }
                    self.namedCount = self.names.count
                    self.stubCount = result.stubCodes
                    self.disasmPct = 100
                    self.busy = false
                    let hit = self.namedInPlist
                    let inj = self.injectCount
                    let msg = "Disassemble OK · \(result.named) getters · mapa \(self.namedCount) · \(hit) no assignment"
                    self.disasmStatus = msg
                    self.status = msg
                    self.ping(msg)
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.error = error.localizedDescription
                    self.status = "Capstone falhou"
                    self.ping("Capstone falhou")
                }
            }
        }
    }

    func loadBundledNames() {
        guard let url = Bundle.main.url(forResource: "ios-abprops-names", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        try? loadNameMap(data)
        namedCount = names.count
        disasmStatus = "mapa Cobalt+iOS · \(namedCount) nomes"
        status = disasmStatus
    }

    func ingestAny(_ data: Data, name: String) throws {
        let lower = name.lowercased()
        if data.count >= 8, data.starts(with: [0x62, 0x70, 0x6c, 0x69, 0x73, 0x74]) {
            try loadPlist(data, name: name)
            return
        }
        if data.count >= 4, data[0] == 0xCF, data[1] == 0xFA, data[2] == 0xED, data[3] == 0xFE {
            loadFramework(data)
            return
        }
        if lower.hasSuffix(".json") || data.first == 0x7B || data.first == 0x5B {
            try loadNameMap(data)
            return
        }
        if lower.contains("sharedmodules") || (lower.contains("whatsapp") && data.count > 1_000_000) {
            loadFramework(data)
            return
        }
        try ingestMobileConfig(data, name: name)
    }

    func addCustom() {
        let code = customCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.allSatisfy(\.isNumber) else {
            error = "Código tem que ser numérico (ex. 1777)."
            return
        }
        let label = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { names[code] = label }
        else if names[code] == nil { names[code] = "custom_\(code)" }
        namedCount = names.count
        var val = customValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if val.isEmpty { val = "1" }
        Keyboard.hide()
        if liveRoot == nil {
            ping("\(code) no mapa — abre um plist pra salvar")
            return
        }
        setFlag(storeKey: personalStore, code: code, value: val)
        ping("Custom \(code) = \(val)")
    }

    func openPatcher() {
        if catalog == nil || liveRoot == nil {
            let scratch = PlistValue.dict([
                ("abp.pnonep", .nested(.dict([]))),
            ])
            catalog = Catalog(
                root: scratch,
                original: scratch,
                originalRaw: scratch,
                originalBytes: nil,
                fileName: "fetch.plist",
                buckets: [
                    Bucket(id: "abp.pnonep", title: "personal", kind: .flags, storeKey: "abp.pnonep", flags: []),
                ]
            )
            liveRoot = scratch
            if plistName.isEmpty { plistName = "fetch.plist" }
        }
        screen = .flags
        ping("Patcher · \(allFlags.count) flags · \(namedCount) nomes")
    }

    func fetchWebABProps() {
        busy = true
        disasmPct = 1
        status = "Fetch Web ABProps…"
        ping("Fetch iniciado (WhatsApp Web)")
        Task {
            do {
                let result = try await WebABProps.fetch { pct, msg in
                    DispatchQueue.main.async {
                        self.disasmPct = pct
                        self.status = msg
                    }
                }
                let json = try JSONSerialization.data(
                    withJSONObject: result.mapValues { ["n": $0.name, "t": $0.type] },
                    options: [.sortedKeys]
                )
                await MainActor.run {
                    for (code, prop) in result {
                        self.names[code] = prop.name
                        self.types[code] = FlagKind.parse(prop.type)
                    }
                    self.namedCount = self.names.count
                    self.lastFetchedJSON = json
                    self.fetched = true
                    self.busy = false
                    self.disasmPct = 100
                    let msg = "Fetch Web OK · \(result.count) props · mapa \(self.namedCount)"
                    self.status = msg
                    self.disasmStatus = msg
                    self.ping(msg)
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.error = error.localizedDescription
                    self.status = "Fetch falhou"
                    self.ping("Fetch falhou")
                }
            }
        }
    }

    func exportNames() throws -> Data {
        if let lastFetchedJSON { return lastFetchedJSON }
        return try JSONSerialization.data(withJSONObject: names, options: [.sortedKeys, .prettyPrinted])
    }

    func loadNameMap(_ data: Data) throws {
        var n = 0
        let obj = try JSONSerialization.jsonObject(with: data)
        if let arr = obj as? [Any] {
            for item in arr {
                guard let s = item as? String else { continue }
                let parts = s.split(separator: ":", maxSplits: 3).map(String.init)
                if parts.count >= 2, parts[0].allSatisfy(\.isNumber) {
                    names[parts[0]] = parts.count >= 4 ? parts[3] : parts[1]
                    n += 1
                }
            }
        } else if let dict = obj as? [String: Any] {
            let src = (dict["byCode"] as? [String: Any]) ?? dict
            for (code, value) in src {
                if let name = value as? String {
                    names[code] = name
                    n += 1
                } else if let arr = value as? [Any], let name = arr.first as? String {
                    names[code] = name
                    n += 1
                } else if let nested = value as? [String: Any] {
                    if let name = nested["n"] as? String {
                        names[code] = name
                        n += 1
                    }
                    if let t = nested["t"] as? String {
                        types[code] = FlagKind.parse(t)
                    }
                }
            }
        } else {
            throw EditorError.message("JSON inválido.")
        }
        namedCount = names.count
        ping("Mapa JSON · +\(n) · total \(names.count)")
        status = "Mapa: \(names.count) nomes"
    }

    func ingestMobileConfig(_ data: Data, name: String) throws {
        if name.contains("params_map") || String(data: data.prefix(3), encoding: .utf8) == "v2,"
            || String(data: data.prefix(20), encoding: .utf8)?.hasPrefix("v2,") == true {
            guard let text = String(data: data, encoding: .utf8) else {
                throw EditorError.message("params_map.txt não é UTF-8.")
            }
            mcConfigs = MobileConfig.parseMap(text)
            mcMapLoaded = true
            ping("params_map · \(mcConfigs.count) configs")
            return
        }
        let lines = try MobileConfig.parseNamesJSON(data)
        MobileConfig.applyNames(lines, onto: &mcConfigs)
        mcNamesLoaded += 1
        ping("\(name) · \(lines.count) linhas · \(mcConfigs.filter { !$0.name.isEmpty }.count) configs com nome")
    }

    func exportMapping() throws -> Data {
        try MobileConfig.mappingJSON(from: mcConfigs)
    }

    func exportOverrides() throws -> Data {
        let selected = mcConfigs.flatMap(\.params).filter { mcSelected.contains($0.id) }
        return try MobileConfig.overridesJSON(selected: selected, values: mcValues, configs: mcConfigs)
    }

    func toggleOverride(_ p: MCParam) {
        if mcSelected.contains(p.id) {
            mcSelected.remove(p.id)
        } else {
            mcSelected.insert(p.id)
            if mcValues[p.id] == nil { mcValues[p.id] = p.type.defaultValue }
        }
    }

    func setFlag(storeKey: String, code: String, value: String) {
        guard let liveRoot else { return }
        self.liveRoot = liveRoot.settingFlag(store: storeKey, code: code, value: value)
    }

    func exportPlist() throws -> Data {
        guard let catalog, let liveRoot else { throw EditorError.message("Nada aberto.") }
        if dirtyCount == 0, let bytes = catalog.originalBytes { return bytes }
        return try catalog.originalRaw.preserving(live: liveRoot).serialize()
    }

    func name(for code: String) -> String? { names[code] }

    func kind(for code: String) -> FlagKind {
        if let t = types[code] { return t }
        if let n = names[code] { return FlagKind.infer(from: n) }
        return .bool
    }

    func ping(_ msg: String) {
        toast = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if toast == msg { toast = nil }
        }
    }
}

enum FlagKind: String {
    case bool, int, string, float, double
    var label: String {
        switch self {
        case .bool: "bool"
        case .int: "int"
        case .string: "str"
        case .float, .double: "num"
        }
    }
    static func parse(_ raw: String) -> FlagKind {
        switch raw.lowercased() {
        case "bool", "boolean": .bool
        case "int", "integer", "long": .int
        case "float", "double", "number": .float
        case "string", "str", "json": .string
        default: .bool
        }
    }
    static func infer(from name: String) -> FlagKind {
        let n = name.lowercased()
        let intTok = ["duration", "count", "size", "length", "timeout", "delay", "limit", "ttl",
                      "days", "hours", "_ms", "interval", "quota", "threshold", "offset",
                      "retries", "capacity", "width", "height", "bytes"]
        if intTok.contains(where: { n.contains($0) }) { return .int }
        if ["ratio", "scale", "multiplier", "factor", "weight"].contains(where: { n.contains($0) }) { return .float }
        if ["url", "uri", "token", "content", "text", "string", "hash", "json", "prefix", "suffix", "path", "host"].contains(where: { n.contains($0) })
            && !n.hasSuffix("_enabled") { return .string }
        return .bool
    }
}

enum FlagTopic: String, CaseIterable, Identifiable {
    case employee, dogfood, glass, bug, intern, mobileConfig, abprop, aura
    var id: String { rawValue }
    var label: String {
        switch self {
        case .employee: "Employee"
        case .dogfood: "Dogfood"
        case .glass: "Glass"
        case .bug: "Bug"
        case .intern: "Internal"
        case .mobileConfig: "MC"
        case .abprop: "ABProp"
        case .aura: "Aura"
        }
    }
    func matches(_ name: String, code: String) -> Bool {
        let n = name.lowercased()
        let f = n.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        switch self {
        case .employee: return f.contains("employee") || code == "1777"
        case .dogfood: return f.contains("dogfood")
        case .glass: return f.contains("liquidglass") || n.contains("liquid_glass")
        case .bug: return f.contains("bugreport") || f.contains("rageshake") || n.contains("bug_report")
        case .intern: return f.contains("internalsetting") || f.contains("internaltester") || f.contains("developer") || n.contains("internal_only")
        case .mobileConfig: return f.contains("mobileconfig")
        case .abprop: return f.contains("abprop")
        case .aura: return n.contains("aura") || n.contains("subscrib") || n.contains("_subs")
        }
    }
}

enum Keyboard {
    static func hide() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

enum EditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}
