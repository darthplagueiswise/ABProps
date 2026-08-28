import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class AppStore {
    var catalog: Catalog?
    var liveRoot: PlistValue?
    var query = ""
    var onlyNamed = false
    var onlyUnnamed = false
    var names: [String: String] = [:]
    var status = "Capstone ARM64 · parado — sobe o SharedModules"
    var disasmPct: Double = 0
    var busy = false
    var error: String?

    var dirtyCount: Int {
        guard let catalog, let liveRoot else { return 0 }
        return catalog.changedCount(live: liveRoot)
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
        error = nil
        status = "\(next.fileName) · \(next.flagCount) flags"
    }

    func loadFramework(_ data: Data) {
        busy = true
        disasmPct = 4
        status = "Capstone: a desmontar ARM64…"
        error = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try MachOExtractor.extract(data)
                DispatchQueue.main.async {
                    guard let self else { return }
                    for (code, name) in result.byCode { self.names[code] = name }
                    self.disasmPct = 100
                    self.status = "Capstone ARM64 · \(result.named) nomes · \(result.stubCodes) getters"
                    self.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self?.error = error.localizedDescription
                    self?.status = "Capstone falhou"
                    self?.busy = false
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
        status = "Mapa: \(n) nomes"
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
}

enum EditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

extension UTType {
    static let macho = UTType(exportedAs: "com.apple.mach-o-binary")
}
