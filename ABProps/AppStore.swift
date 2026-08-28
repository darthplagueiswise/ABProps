import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class AppStore {
    var catalog: Catalog?
    var liveRoot: PlistValue?
    var query = ""
    var onlyNamed = false
    var onlyChanged = false
    var names: [String: String] = [:]
    var status = ""
    var error: String?

    var dirtyCount: Int {
        guard let catalog, let liveRoot else { return 0 }
        return catalog.changedCount(live: liveRoot)
    }

    func loadPlist(_ data: Data, name: String) throws {
        let parsed = try PlistValue.parse(data).unwrapped()
        let next = Catalog.build(root: parsed, fileName: name)
        if next.buckets.isEmpty {
            throw EditorError.message("Sem chaves abp./gabp. neste plist.")
        }
        catalog = next
        liveRoot = next.root
        error = nil
        status = "\(next.fileName) · \(next.flagCount) flags"
    }

    func loadFramework(_ data: Data) throws {
        let result = try MachOExtractor.extract(data)
        for (code, name) in result.byCode {
            names[code] = name
        }
        status = "Framework: \(result.named) nomes · \(result.stubCodes) códigos"
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
        guard let liveRoot else { throw EditorError.message("Nada aberto.") }
        return try liveRoot.wrapped().serialize()
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
