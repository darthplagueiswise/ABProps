import Foundation
import CoreFoundation
import Observation

/// Decodes plist XML/binary, JSON and Base64 envelopes without loading archived classes.
/// NSKeyedArchiver payloads remain their actual $objects / $top graph, including UID references.
indirect enum UniversalEncoding {
    case xml, binary, json, base64(UniversalEncoding)

    var title: String {
        switch self {
        case .xml: return "XML plist"
        case .binary: return "Binary plist"
        case .json: return "JSON"
        case .base64(let inner): return "Base64 → " + inner.title
        }
    }
}

enum UniversalExport: String, CaseIterable, Identifiable {
    case original = "Formato original"
    case xml = "XML plist"
    case binary = "Binary plist"
    case json = "JSON tipado"
    case base64XML = "Base64 (XML)"
    case base64Binary = "Base64 (binário)"
    case base64JSON = "Base64 (JSON)"
    var id: String { rawValue }
    var filenameExtension: String {
        switch self {
        case .original: return "plist"
        case .xml, .binary: return "plist"
        case .json: return "json"
        case .base64XML, .base64Binary, .base64JSON: return "b64"
        }
    }
}

enum UniversalError: LocalizedError {
    case invalidFormat, unsupported(String), invalidValue(String)
    var errorDescription: String? {
        switch self {
        case .invalidFormat: return "Não foi possível identificar um plist, JSON ou Base64 válido."
        case .unsupported(let reason): return "Exportação não suportada com segurança: " + reason
        case .invalidValue(let reason): return "Valor inválido: " + reason
        }
    }
}

enum UniversalPathPart: Hashable {
    case key(String), index(Int), embedded
}

struct UniversalNodeRef: Identifiable {
    let title: String
    let path: [UniversalPathPart]
    var id: String {
        path.map {
            switch $0 {
            case .key(let name): return "k:" + name
            case .index(let index): return "i:" + String(index)
            case .embedded: return "embedded"
            }
        }.joined(separator: "/")
    }
}

enum UniversalPlistCodec {
    static let binarySignature = Data("bplist00".utf8)
    static let markerKey = "__universal_plist_type__"
    static let maxNesting = 16

    struct Decoded {
        let object: Any
        let encoding: UniversalEncoding
    }

    static func decode(_ bytes: Data, level: Int = 0) throws -> Decoded {
        guard level <= maxNesting else { throw UniversalError.unsupported("profundidade excedida") }
        var kind = PropertyListSerialization.PropertyListFormat.binary
        if let value = try? PropertyListSerialization.propertyList(
            from: bytes, options: [], format: &kind
        ) {
            return Decoded(object: value, encoding: kind == .binary ? .binary : .xml)
        }
        if let value = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) {
            return Decoded(object: restoreTaggedJSON(value), encoding: .json)
        }
        guard let string = String(data: bytes, encoding: .utf8) else { throw UniversalError.invalidFormat }
        let compact = string.filter { !$0.isWhitespace }
        guard !compact.isEmpty,
              compact.count % 4 == 0,
              compact.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) ||
                  ($0 >= 48 && $0 <= 57) || $0 == 43 || $0 == 47 || $0 == 61 }),
              let decoded = Data(base64Encoded: compact), !decoded.isEmpty,
              let inner = try? decode(decoded, level: level + 1)
        else { throw UniversalError.invalidFormat }
        return Decoded(object: inner.object, encoding: .base64(inner.encoding))
    }

    static func embedded(_ value: Any) -> Decoded? {
        if let raw = value as? Data { return try? decode(raw) }
        if let raw = value as? String { return try? decode(Data(raw.utf8)) }
        return nil
    }

    static func encode(_ object: Any, as encoding: UniversalEncoding) throws -> Data {
        switch encoding {
        case .xml, .binary:
            do {
                return try PropertyListSerialization.data(
                    fromPropertyList: object,
                    format: {
                        if case .binary = encoding { return .binary }
                        return .xml
                    }(),
                    options: 0
                )
            } catch {
                throw UniversalError.unsupported(
                    "o objeto contém referências ou tipos que o serializador Apple não aceita: " +
                    error.localizedDescription
                )
            }
        case .json:
            let tagged = try jsonSafe(object)
            guard JSONSerialization.isValidJSONObject(tagged) else {
                // Scalar JSON roots require .fragmentsAllowed.
                return try JSONSerialization.data(withJSONObject: tagged, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys])
            }
            return try JSONSerialization.data(withJSONObject: tagged, options: [.prettyPrinted, .sortedKeys])
        case .base64(let inner):
            return Data(try encode(object, as: inner).base64EncodedString().utf8)
        }
    }

    static func export(_ object: Any, format: UniversalExport,
                       original: Data, encoding: UniversalEncoding,
                       dirty: Bool) throws -> Data {
        switch format {
        case .original:
            return dirty ? try encode(object, as: encoding) : original
        case .xml: return try encode(object, as: .xml)
        case .binary: return try encode(object, as: .binary)
        case .json: return try encode(object, as: .json)
        case .base64XML: return try encode(object, as: .base64(.xml))
        case .base64Binary: return try encode(object, as: .base64(.binary))
        case .base64JSON: return try encode(object, as: .base64(.json))
        }
    }

    private static func jsonSafe(_ any: Any) throws -> Any {
        if let value = any as? Data {
            return [markerKey: "data", "base64": value.base64EncodedString()]
        }
        if let value = any as? Date {
            return [markerKey: "date", "iso8601": ISO8601DateFormatter().string(from: value)]
        }
        if let value = any as? NSNumber {
            return value
        }
        if let value = any as? String { return value }
        if let dictionary = any as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, value) in dictionary {
                result[key] = try jsonSafe(value)
            }
            return result
        }
        if let array = any as? [Any] {
            return try array.map(jsonSafe)
        }
        if any is NSNull { return NSNull() }
        throw UniversalError.unsupported(
            "objeto " + String(describing: type(of: any)) +
            " (por exemplo, UID de NSKeyedArchiver): mantenha o arquivo original para não perder referências"
        )
    }

    private static func restoreTaggedJSON(_ any: Any) -> Any {
        if let array = any as? [Any] { return array.map(restoreTaggedJSON) }
        if let dictionary = any as? [String: Any] {
            if dictionary.count == 2,
               let tag = dictionary[markerKey] as? String {
                if tag == "data", let text = dictionary["base64"] as? String,
                   let data = Data(base64Encoded: text) { return data }
                if tag == "date", let text = dictionary["iso8601"] as? String,
                   let date = ISO8601DateFormatter().date(from: text) { return date }
            }
            return dictionary.mapValues(restoreTaggedJSON)
        }
        return any
    }


    /// Exhaustive depth-first search; array items are NEVER summarized or skipped.
    /// Returned paths locate the precise matching key/value, including decoded embedded data.
    static func fullTextMatches(_ root: Any, query: String) -> [UniversalNodeRef] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var stack: [(Any, [UniversalPathPart], Int)] = [(root, [], 0)]
        var matches: [UniversalNodeRef] = []
        while let (value, path, embeddingDepth) = stack.popLast() {
            if let dictionary = value as? [String: Any] {
                for key in dictionary.keys.sorted().reversed() {
                    guard let child = dictionary[key] else { continue }
                    let childPath = path + [.key(key)]
                    if key.localizedStandardContains(needle) {
                        matches.append(UniversalNodeRef(title: key, path: childPath))
                    } else if children(child, path: childPath).isEmpty &&
                              summary(child).localizedStandardContains(needle) {
                        matches.append(UniversalNodeRef(title: key, path: childPath))
                    }
                    stack.append((child, childPath, embeddingDepth))
                }
            } else if let array = value as? [Any] {
                // Reverse push preserves ascending display order.
                for index in array.indices.reversed() {
                    let child = array[index]
                    let childPath = path + [.index(index)]
                    if children(child, path: childPath).isEmpty &&
                       summary(child).localizedStandardContains(needle) {
                        matches.append(UniversalNodeRef(title: "[" + String(index) + "]", path: childPath))
                    }
                    stack.append((child, childPath, embeddingDepth))
                }
            } else if embeddingDepth < maxNesting, let decoded = embedded(value) {
                stack.append((decoded.object, path + [.embedded], embeddingDepth + 1))
            } else if path.isEmpty && summary(value).localizedStandardContains(needle) {
                matches.append(UniversalNodeRef(title: "Raiz", path: []))
            }
        }
        // One match per structural path, rather than repeated matching parent summaries.
        var seen = Set<String>()
        return matches.filter { seen.insert($0.id).inserted }
    }

    static func pathLabel(_ path: [UniversalPathPart]) -> String {
        if path.isEmpty { return "/" }
        return path.map {
            switch $0 {
            case .key(let k): return k
            case .index(let index): return "[" + String(index) + "]"
            case .embedded: return "(decodificado)"
            }
        }.joined(separator: " / ")
    }

    static func kind(_ value: Any) -> String {
        if value is [String: Any] { return "Dicionário" }
        if value is [Any] { return "Array" }
        if value is Data { return "Dados" }
        if value is Date { return "Data/hora" }
        if value is String { return "Texto" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return "Booleano" }
            return isReal(number) ? "Real" : "Inteiro"
        }
        return String(describing: type(of: value))
    }

    static func isReal(_ value: NSNumber) -> Bool {
        let code = String(cString: value.objCType)
        return code == "f" || code == "d"
    }

    static func summary(_ value: Any) -> String {
        if let map = value as? [String: Any] { return String(map.count) + " chaves" }
        if let array = value as? [Any] { return String(array.count) + " elementos" }
        if let data = value as? Data {
            return String(data.count) + " bytes" + (embedded(data).map { " · " + $0.encoding.title } ?? "")
        }
        if let string = value as? String {
            return String(string.prefix(120)) + (string.count > 120 ? "…" : "")
        }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    static func children(_ value: Any, path: [UniversalPathPart]) -> [UniversalNodeRef] {
        if let pairs = value as? [String: Any] {
            return pairs.keys.sorted().map { UniversalNodeRef(title: $0, path: path + [.key($0)]) }
        }
        if let array = value as? [Any] {
            return array.enumerated().map { index, _ in
                UniversalNodeRef(title: "[" + String(index) + "]", path: path + [.index(index)])
            }
        }
        if embedded(value) != nil {
            return [UniversalNodeRef(title: "Conteúdo decodificado", path: path + [.embedded])]
        }
        return []
    }

    static func value(_ root: Any, at path: [UniversalPathPart]) throws -> Any {
        var cursor: Any = root
        for step in path {
            switch step {
            case .key(let key):
                guard let map = cursor as? [String: Any], let next = map[key] else {
                    throw UniversalError.invalidValue("chave " + key)
                }
                cursor = next
            case .index(let index):
                guard let values = cursor as? [Any], values.indices.contains(index) else {
                    throw UniversalError.invalidValue("índice " + String(index))
                }
                cursor = values[index]
            case .embedded:
                guard let next = embedded(cursor) else { throw UniversalError.invalidFormat }
                cursor = next.object
            }
        }
        return cursor
    }

    /// Rebuilds each parent on the way back to the root; a failed write leaves the model untouched.
    static func replacing(_ parent: Any, at path: ArraySlice<UniversalPathPart>,
                          with newValue: Any) throws -> Any {
        guard let first = path.first else { return newValue }
        let remaining = path.dropFirst()
        switch first {
        case .key(let key):
            guard var map = parent as? [String: Any], let old = map[key] else {
                throw UniversalError.invalidValue("chave " + key)
            }
            map[key] = try replacing(old, at: remaining, with: newValue)
            return map
        case .index(let index):
            guard var values = parent as? [Any], values.indices.contains(index) else {
                throw UniversalError.invalidValue("índice " + String(index))
            }
            values[index] = try replacing(values[index], at: remaining, with: newValue)
            return values
        case .embedded:
            guard let decoded = embedded(parent) else { throw UniversalError.invalidFormat }
            let updated = try replacing(decoded.object, at: remaining, with: newValue)
            let bytes = try encode(updated, as: decoded.encoding)
            if parent is Data { return bytes }
            if parent is String { return String(decoding: bytes, as: UTF8.self) }
            throw UniversalError.invalidFormat
        }
    }

    static func scalar(_ text: String, matching previous: Any) throws -> Any {
        if previous is String { return text }
        if previous is Data {
            let compact = text.filter { !$0.isWhitespace }
            guard let bytes = Data(base64Encoded: compact) else {
                throw UniversalError.invalidValue("Base64 inválido")
            }
            return bytes
        }
        if previous is Date {
            guard let value = ISO8601DateFormatter().date(from: text) else {
                throw UniversalError.invalidValue("use ISO 8601, por exemplo 2026-10-25T04:00:00Z")
            }
            return value
        }
        if let number = previous as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                guard text == "true" || text == "false" else {
                    throw UniversalError.invalidValue("use true ou false")
                }
                return NSNumber(value: text == "true")
            }
            if isReal(number) {
                guard let value = Double(text), value.isFinite else {
                    throw UniversalError.invalidValue("número real inválido")
                }
                return NSNumber(value: value)
            }
            if let value = Int64(text) { return NSNumber(value: value) }
            if let value = UInt64(text) { return NSNumber(value: value) }
            throw UniversalError.invalidValue("inteiro de 64 bits inválido")
        }
        throw UniversalError.unsupported("edição desse tipo de objeto")
    }

    static func editableText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let data = value as? Data { return data.base64EncodedString() }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        return nil
    }
}

@Observable
@MainActor
final class UniversalDocumentStore {
    var root: Any?
    var original: Data?
    var encoding: UniversalEncoding?
    var fileName = ""
    var sourceURL: URL?
    var dirty = false
    var error: String?
    private var undoStack: [Any] = []

    func open(_ bytes: Data, name: String) throws {
        let document = try UniversalPlistCodec.decode(bytes)
        root = document.object
        original = bytes
        encoding = document.encoding
        fileName = name
        sourceURL = nil
        dirty = false
        error = nil
        undoStack.removeAll()
    }

    func value(at path: [UniversalPathPart]) -> Any? {
        guard let root else { return nil }
        return try? UniversalPlistCodec.value(root, at: path)
    }

    func change(at path: [UniversalPathPart], text: String) throws {
        guard let root else { throw UniversalError.invalidFormat }
        let previous = try UniversalPlistCodec.value(root, at: path)
        let scalar = try UniversalPlistCodec.scalar(text, matching: previous)
        let updated = try UniversalPlistCodec.replacing(root, at: path[...], with: scalar)
        undoStack.append(root)
        self.root = updated
        dirty = true
    }

    /// Saves changes to the imported document using Apple's coordinated file access.
    /// Unlike Export, Save retains the exact original envelope (including Base64).
    func save() throws {
        guard let url = sourceURL, let root, let original, let encoding else {
            throw UniversalError.unsupported("não existe um arquivo original gravável; use Exportar")
        }
        let data = try UniversalPlistCodec.export(
            root, format: .original, original: original, encoding: encoding, dirty: dirty
        )
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing,
                               error: &coordinationError) { target in
            do { try data.write(to: target, options: [.atomic]) }
            catch { writeError = error }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
        self.original = data
        dirty = false
        undoStack.removeAll()
    }

    func undo() {
        guard let old = undoStack.popLast() else { return }
        root = old
        dirty = !undoStack.isEmpty
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func export(_ format: UniversalExport) throws -> (Data, String) {
        guard let root, let original, let encoding else { throw UniversalError.invalidFormat }
        let bytes = try UniversalPlistCodec.export(
            root, format: format, original: original, encoding: encoding, dirty: dirty
        )
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let name = (base.isEmpty ? "documento" : base) + "-export." + (
            format == .original ? originalExtension(encoding) : format.filenameExtension
        )
        return (bytes, name)
    }

    private func originalExtension(_ encoding: UniversalEncoding) -> String {
        switch encoding {
        case .xml, .binary: return "plist"
        case .json: return "json"
        case .base64: return "b64"
        }
    }
}
