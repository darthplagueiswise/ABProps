import Foundation
import Observation
import UniformTypeIdentifiers

enum AppScreen: Hashable {
    case home
    case flags
    case mobileConfig
}

@Observable
@MainActor
final class AppStore {
    var screen: AppScreen = .home
    var catalog: Catalog?
    var liveRoot: PlistValue?
    var query = ""
    var names: [String: String] = [:]
    var status = "À espera de ficheiros"
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

    var dirtyCount: Int {
        guard let catalog, let liveRoot else { return 0 }
        return catalog.changedCount(live: liveRoot)
    }

    var allFlags: [FlagRow] {
        guard let catalog else { return [] }
        var best: [String: FlagRow] = [:]
        let order = catalog.buckets.filter { $0.kind == .flags }.sorted { Catalog.weight($0.storeKey) < Catalog.weight($1.storeKey) }
        for b in order {
            for r in b.flags { best[r.code] = r }
        }
        return best.values.sorted { (Int($0.code) ?? 0) < (Int($1.code) ?? 0) }
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
        ping("Plist: \(next.flagCount) flags")
        status = "\(name) · \(next.flagCount) flags · \(namedCount) nomes"
    }

    func loadFramework(_ data: Data) {
        busy = true
        disasmPct = 2
        status = "Capstone: a desmontar ARM64…"
        ping("Capstone iniciado · \(data.count / 1_000_000) MB")
        error = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try MachOExtractor.extract(data) { pct, msg in
                    Task { @MainActor in
                        self?.disasmPct = pct
                        self?.status = msg
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    for (code, name) in result.byCode { self.names[code] = name }
                    self.namedCount = result.named
                    self.stubCount = result.stubCodes
                    self.disasmPct = 100
                    self.busy = false
                    let msg = "Disassemble OK · \(result.named) nomes · \(result.stubCodes) getters"
                    self.status = msg
                    self.ping(msg)
                }
            } catch {
                await MainActor.run {
                    self?.busy = false
                    self?.error = error.localizedDescription
                    self?.status = "Capstone falhou"
                    self?.ping("Capstone falhou")
                }
            }
        }
    }

    func loadNameMap(_ data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditorError.message("JSON inválido.")
        }
        var n = 0
        let src = (obj["byCode"] as? [String: Any]) ?? obj
        for (code, value) in src {
            if let name = value as? String {
                names[code] = name
                n += 1
            } else if let arr = value as? [Any], let name = arr.first as? String {
                names[code] = name
                n += 1
            }
        }
        namedCount = names.count
        ping("Mapa JSON · \(n) nomes")
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

    func ping(_ msg: String) {
        toast = msg
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            if toast == msg { toast = nil }
        }
    }
}

enum EditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}
