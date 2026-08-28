import Foundation

enum MCType: String, Codable {
    case bool, int, string, double

    static func decode(_ hex: String) -> MCType {
        if hex.isEmpty { return .bool }
        let v = Int(hex, radix: 16) ?? 0
        switch v & 0x3F {
        case 0, 4, 6: return .bool
        case 8, 0xA: return .int
        case 0xC, 0xD, 0xE, 0xF: return .string
        case 0x10, 0x12: return .double
        default:
            if v & 0x10 != 0 { return .double }
            if v & 0x08 != 0 { return .int }
            return .bool
        }
    }

    var defaultValue: String {
        switch self {
        case .bool: return "true"
        case .int: return "1"
        case .double: return "1.0"
        case .string: return ""
        }
    }
}

struct MCParam: Identifiable, Hashable {
    var id: String { "\(configId):\(index)" }
    let configId: Int
    let index: Int
    var name: String
    var type: MCType
    var specifier: Int
}

struct MCConfig: Identifiable {
    var id: Int { configId }
    var configId: Int
    var name: String
    var params: [MCParam]

    var mappingLine: String? {
        let named = params.filter { !$0.name.isEmpty }
        guard !name.isEmpty || !named.isEmpty else { return nil }
        var parts = [String(configId), name]
        for p in named.sorted(by: { $0.index < $1.index }) {
            parts.append(String(p.index))
            parts.append(p.name)
        }
        return parts.joined(separator: ":")
    }

    var key: String { "\(configId):\(name)" }
}

enum MobileConfig {
    static func hex(_ s: String) -> Int {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        if t.hasPrefix("-") { return -(Int(t.dropFirst(), radix: 16) ?? 0) }
        return Int(t, radix: 16) ?? 0
    }

    static func parseMap(_ text: String) -> [MCConfig] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first, first.hasPrefix("v2") || first.hasPrefix("v1") else {
            return []
        }
        var configs: [MCConfig] = []
        var cur: MCConfig?
        var idx = 0
        func flush() {
            if let c = cur { configs.append(c) }
            cur = nil
        }
        for line in lines.dropFirst() {
            if line.hasPrefix("*") {
                flush()
                let parts = String(line.dropFirst()).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                let name = parts[safe: 0] ?? ""
                let delta = parts[safe: 1] ?? ""
                let cid = parts[safe: 2] ?? ""
                idx = hex(delta)
                cur = MCConfig(configId: hex(cid), name: name, params: [])
                continue
            }
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let pname = parts[safe: 0] ?? ""
            let pdelta = parts[safe: 1] ?? ""
            let ptype = parts[safe: 2] ?? ""
            let pspec = parts[safe: 3] ?? ""
            idx += pdelta.isEmpty ? 1 : hex(pdelta)
            guard var c = cur else { continue }
            c.params.append(MCParam(
                configId: c.configId,
                index: idx,
                name: pname,
                type: MCType.decode(ptype),
                specifier: hex(pspec)
            ))
            cur = c
        }
        flush()
        return configs
    }

    static func parseNamesJSON(_ data: Data) throws -> [String] {
        let obj = try JSONSerialization.jsonObject(with: data)
        if let arr = obj as? [String] { return arr }
        if let dict = obj as? [String: Any] {
            if let arr = dict["id_name_mapping"] as? [String] { return arr }
            if let arr = dict["mapping"] as? [String] { return arr }
        }
        throw EditorError.message("JSON de nomes inválido (espera array de strings).")
    }

    static func applyNames(_ lines: [String], onto configs: inout [MCConfig]) {
        var byId: [Int: Int] = [:]
        for (i, c) in configs.enumerated() { byId[c.configId] = i }
        for line in lines {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard let id = Int(parts.first ?? "") else { continue }
            let name = parts[safe: 1] ?? ""
            var pairs: [(Int, String)] = []
            var i = 2
            while i + 1 < parts.count {
                if let idx = Int(parts[i]) {
                    pairs.append((idx, parts[i + 1]))
                }
                i += 2
            }
            if let pos = byId[id] {
                configs[pos].name = configs[pos].name.isEmpty ? name : configs[pos].name
                var pByIdx: [Int: Int] = [:]
                for (j, p) in configs[pos].params.enumerated() { pByIdx[p.index] = j }
                for (idx, pname) in pairs {
                    if let j = pByIdx[idx] {
                        if configs[pos].params[j].name.isEmpty { configs[pos].params[j].name = pname }
                    } else {
                        configs[pos].params.append(MCParam(
                            configId: id, index: idx, name: pname, type: .bool, specifier: 0
                        ))
                        pByIdx[idx] = configs[pos].params.count - 1
                    }
                }
            } else {
                let params = pairs.map { MCParam(configId: id, index: $0.0, name: $0.1, type: .bool, specifier: 0) }
                configs.append(MCConfig(configId: id, name: name, params: params))
                byId[id] = configs.count - 1
            }
        }
    }

    static func mappingJSON(from configs: [MCConfig]) throws -> Data {
        let lines = configs
            .sorted { $0.configId < $1.configId }
            .compactMap(\.mappingLine)
        return try JSONSerialization.data(withJSONObject: lines, options: [.prettyPrinted])
    }

    static func overridesJSON(selected: [MCParam], values: [String: String], configs: [MCConfig]) throws -> Data {
        var byCfg: [Int: [MCParam]] = [:]
        for p in selected { byCfg[p.configId, default: []].append(p) }
        var nameOf: [Int: String] = [:]
        for c in configs { nameOf[c.configId] = c.name }
        var obj: [String: Any] = [:]
        for (cid, params) in byCfg.sorted(by: { $0.key < $1.key }) {
            let key = "\(cid):\(nameOf[cid] ?? "")"
            let rows = params.sorted { $0.index < $1.index }.map { p -> String in
                let val = values[p.id] ?? p.type.defaultValue
                return "\(p.index): \(p.name): \(val)"
            }
            obj[key] = rows
        }
        obj["_qe_overrides_"] = [] as [Any]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
