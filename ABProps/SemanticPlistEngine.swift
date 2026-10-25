import Foundation
import CoreFoundation

/// Displays actual decoded values, not reversible-envelope implementation details.
/// The source bytes are retained separately and supply type information during export.
enum SemanticPlistEngine {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return message }
        }
    }

    static let nullKey = "__json_null__"
    static let nilArchive = "(nil)"
    static let maxDepth = 32

    struct Input {
        let source: Data
        let kind: UniversalEncoding
        let semantic: Any
        let text: String
    }

    static func open(_ data: Data) throws -> Input {
        let decoded = try UniversalPlistCodec.decode(data)
        let semantic = try project(decoded.object, depth: 0)
        let xml = try xmlString(semantic)
        return Input(source: data, kind: decoded.encoding, semantic: semantic, text: xml)
    }

    static func xmlString(_ object: Any) throws -> String {
        let bytes = try PropertyListSerialization.data(
            fromPropertyList: object, format: .xml, options: 0
        )
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw Failure.invalid("Falha ao gerar XML UTF-8.")
        }
        return value
    }

    static func parseXML(_ text: String) throws -> Any {
        guard let bytes = text.data(using: .utf8) else {
            throw Failure.invalid("Documento não é UTF-8.")
        }
        return try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil)
    }

    static func save(_ editedXML: String, original: Data,
                     kind: UniversalEncoding) throws -> Data {
        let edited = try parseXML(editedXML)
        let raw = try UniversalPlistCodec.decode(original).object
        let reconstructed = try restore(raw, edited: edited, depth: 0)
        return try UniversalPlistCodec.encode(reconstructed, as: kind)
    }

    static func export(_ editedXML: String, original: Data,
                       kind: UniversalEncoding, as format: UniversalEncoding) throws -> Data {
        let edited = try parseXML(editedXML)
        let raw = try UniversalPlistCodec.decode(original).object
        let reconstructed = try restore(raw, edited: edited, depth: 0)
        return try UniversalPlistCodec.encode(reconstructed, as: format)
    }

    // Only inspect formats with a verified signature. Generic numbers and base64-like
    // IDs MUST remain strings. The previous release recursively turned them into junk.
    private static func structured(_ data: Data) -> Bool {
        if data.starts(with: Data("bplist00".utf8)) { return true }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.hasPrefix("{") || cleaned.hasPrefix("[") ||
            cleaned.hasPrefix("<plist") || cleaned.hasPrefix("<?xml")
    }

    private static func embedded(_ object: Any) -> UniversalPlistCodec.Decoded? {
        if let bytes = object as? Data {
            guard structured(bytes) else { return nil }
            return try? UniversalPlistCodec.decode(bytes)
        }
        guard let value = object as? String else { return nil }
        let bytes = Data(value.utf8)
        if structured(bytes) { return try? UniversalPlistCodec.decode(bytes) }
        let compact = value.filter { !$0.isWhitespace }
        guard compact.count >= 16, compact.count % 4 == 0,
              let decoded = Data(base64Encoded: compact),
              structured(decoded),
              let nested = try? UniversalPlistCodec.decode(decoded) else { return nil }
        return UniversalPlistCodec.Decoded(object: nested.object, encoding: .base64(nested.encoding))
    }

    private static func project(_ object: Any, depth: Int) throws -> Any {
        guard depth < maxDepth else {
            throw Failure.invalid("A profundidade de dados codificados excede o limite de 32 níveis.")
        }
        if object is NSNull { return [nullKey: true] }
        if let nested = embedded(object) {
            if isArchive(nested.object) {
                return try archiveView(nested.object)
            }
            return try project(nested.object, depth: depth + 1)
        }
        if let map = object as? [String: Any] {
            var expanded: [String: Any] = [:]
            for (key, value) in map {
                expanded[key] = try project(value, depth: depth + 1)
            }
            return expanded
        }
        if let items = object as? [Any] {
            return try items.map { try project($0, depth: depth + 1) }
        }
        return object
    }

    private static func isArchive(_ object: Any) -> Bool {
        guard let map = object as? [String: Any] else { return false }
        return map["$archiver"] as? String == "NSKeyedArchiver" &&
               map["$objects"] is [Any] && map["$top"] is [String: Any]
    }

    // Convert UID object references into a friendly object tree:
    // NSArray -> <array>; NSDate -> <date>; normal classes -> field dictionary.
    private static func archiveView(_ object: Any) throws -> Any {
        let bridge = try archiveBridge(object)
        guard let graph = bridge as? [String: Any],
              let objects = graph["$objects"] as? [Any],
              let top = graph["$top"] as? [String: Any],
              let root = top["root"] else {
            throw Failure.invalid("NSKeyedArchiver sem tabela de objetos válida.")
        }
        return try archiveResolve(root, objects: objects, depth: 0, visiting: [])
    }

    private static func archiveBridge(_ object: Any) throws -> Any {
        // CFKeyedArchiverUID becomes the portable CF$UID dict in XML.
        let xml = try PropertyListSerialization.data(
            fromPropertyList: object, format: .xml, options: 0
        )
        return try PropertyListSerialization.propertyList(from: xml, options: [], format: nil)
    }

    private static func uid(_ object: Any) -> Int? {
        if let map = object as? [String: Any], map.count == 1,
           let value = map["CF$UID"] as? NSNumber { return value.intValue }
        // Apple's binary plist reader returns the private CFKeyedArchiverUID value
        // directly, not a dictionary. We inspect its descriptive numeric value
        // without instantiating or invoking private classes.
        let description = String(describing: object)
        guard description.hasPrefix("<CFKeyedArchiverUID "),
              let marker = description.range(of: "value = ") else { return nil }
        let remaining = description[marker.upperBound...]
        let digits = remaining.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func archiveClass(_ object: [String: Any], objects: [Any]) -> String {
        guard let cls = object["$class"], let index = uid(cls),
              objects.indices.contains(index),
              let classEntry = objects[index] as? [String: Any] else { return "" }
        return classEntry["$classname"] as? String ?? ""
    }

    private static func archiveResolve(_ input: Any, objects: [Any],
                                       depth: Int, visiting: Set<Int>) throws -> Any {
        guard depth < 50 else { throw Failure.invalid("NSKeyedArchiver contém referências excessivamente profundas.") }
        if let index = uid(input) {
            if index == 0 { return nilArchive }
            guard objects.indices.contains(index) else {
                throw Failure.invalid("UID \(index) fora da tabela de objetos.")
            }
            guard !visiting.contains(index) else {
                return "(referência compartilhada UID \(index))"
            }
            var next = visiting
            next.insert(index)
            return try archiveResolve(objects[index], objects: objects, depth: depth + 1, visiting: next)
        }
        if let map = input as? [String: Any] {
            let className = archiveClass(map, objects: objects)
            if className.hasSuffix("Array"), let items = map["NS.objects"] as? [Any] {
                return try items.map { try archiveResolve($0, objects: objects,
                                                           depth: depth + 1, visiting: visiting) }
            }
            if className.hasSuffix("Dictionary"),
               let keys = map["NS.keys"] as? [Any],
               let values = map["NS.objects"] as? [Any], keys.count == values.count {
                var readable: [String: Any] = [:]
                for (keyReference, valueReference) in zip(keys, values) {
                    let key = try archiveResolve(keyReference, objects: objects,
                                                 depth: depth + 1, visiting: visiting)
                    guard let name = key as? String else {
                        throw Failure.invalid("NSDictionary arquivado com chave não textual.")
                    }
                    readable[name] = try archiveResolve(valueReference, objects: objects,
                                                        depth: depth + 1, visiting: visiting)
                }
                return readable
            }
            if className == "NSDate", let seconds = map["NS.time"] as? NSNumber {
                return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
            }
            if className == "NSData", let bytes = map["NS.data"] as? Data { return bytes }
            if className == "NSString", let str = map["NS.string"] as? String { return str }
            var pretty: [String: Any] = [:]
            if !className.isEmpty { pretty["_class"] = className }
            for (key, value) in map where key != "$class" {
                pretty[key] = try archiveResolve(value, objects: objects,
                                                  depth: depth + 1, visiting: visiting)
            }
            return pretty
        }
        if let items = input as? [Any] {
            return try items.map { try archiveResolve($0, objects: objects,
                                                       depth: depth + 1, visiting: visiting) }
        }
        return input
    }

    private static func restore(_ old: Any, edited: Any, depth: Int) throws -> Any {
        guard depth < maxDepth else { throw Failure.invalid("Documento excessivamente aninhado.") }
        if let oldNested = embedded(old) {
            let oldVisible: Any
            if isArchive(oldNested.object) {
                oldVisible = try archiveView(oldNested.object)
            } else {
                oldVisible = try project(oldNested.object, depth: depth + 1)
            }
            if equal(oldVisible, edited) { return old } // byte-for-byte internal preservation
            let rebuiltInner: Any
            if isArchive(oldNested.object) {
                rebuiltInner = try archiveMerge(oldNested.object, edited: edited)
            } else {
                rebuiltInner = try restore(oldNested.object, edited: edited, depth: depth + 1)
            }
            let raw = try UniversalPlistCodec.encode(rebuiltInner, as: oldNested.encoding)
            if old is Data { return raw }
            guard let text = String(data: raw, encoding: .utf8) else {
                throw Failure.invalid("Conteúdo textual reconstruído não é UTF-8.")
            }
            return text
        }
        if old is NSNull {
            if let map = edited as? [String: Any], map[nullKey] as? Bool == true { return NSNull() }
            throw Failure.invalid("Null JSON deve manter o marcador \(nullKey).")
        }
        if let oldMap = old as? [String: Any], let newMap = edited as? [String: Any] {
            var result = newMap
            for (key, value) in newMap {
                if let previous = oldMap[key] {
                    result[key] = try restore(previous, edited: value, depth: depth + 1)
                }
            }
            return result
        }
        if let oldList = old as? [Any], let newList = edited as? [Any] {
            return try newList.enumerated().map { index, entry in
                if oldList.indices.contains(index) {
                    return try restore(oldList[index], edited: entry, depth: depth + 1)
                }
                return entry
            }
        }
        return edited
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool {
        if let d1 = a as? [String: Any], let d2 = b as? [String: Any] {
            return d1.count == d2.count && d1.allSatisfy { key, value in
                d2[key].map { other in equal(value, other) } ?? false
            }
        }
        if let v1 = a as? [Any], let v2 = b as? [Any] {
            return v1.count == v2.count && zip(v1,v2).allSatisfy { equal($0.0,$0.1) }
        }
        if let x = a as? Data, let y = b as? Data { return x == y }
        if let x = a as? Date, let y = b as? Date { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y && CFGetTypeID(x) == CFGetTypeID(y) }
        return String(describing: a) == String(describing: b)
    }

    private static func archiveMerge(_ old: Any, edited: Any) throws -> Any {
        // Use the original binary graph, never recreate the archive classes/UID table.
        guard var archive = old as? [String: Any],
              var objects = archive["$objects"] as? [Any],
              let top = archive["$top"] as? [String: Any],
              let root = top["root"] else {
            throw Failure.invalid("Arquivo NSKeyedArchiver original inválido.")
        }
        var changed = Set<Int>()
        try archivePatch(root, edited: edited, objects: &objects, changed: &changed, depth: 0)
        archive["$objects"] = objects
        return archive
    }

    private static func archivePatch(_ original: Any, edited: Any,
                                     objects: inout [Any], changed: inout Set<Int>,
                                     depth: Int) throws {
        guard depth < 50 else { throw Failure.invalid("UID recursivo inválido.") }
        if let ref = uid(original) {
            if ref == 0 {
                guard (edited as? String) == nilArchive else {
                    throw Failure.invalid("Não é possível modificar uma referência nil do arquivo.")
                }
                return
            }
            guard objects.indices.contains(ref) else { throw Failure.invalid("UID inválido.") }
            let oldNode = objects[ref]
            let oldView = try archiveResolve(oldNode, objects: objects, depth: depth + 1,
                                             visiting: [ref])
            if equal(oldView, edited) { return }
            guard !changed.contains(ref) else {
                throw Failure.invalid("Objeto UID \(ref) compartilhado: referências divergentes exigem edição coordenada.")
            }
            changed.insert(ref)
            try archivePatch(oldNode, edited: edited, objects: &objects,
                             changed: &changed, depth: depth + 1)
            // For simple object table entries patch the actual referent, preserving UID.
            if !(oldNode is [String: Any]) && !(oldNode is [Any]) {
                objects[ref] = edited
            }
            return
        }
        if var dict = original as? [String: Any] {
            let className = archiveClass(dict, objects: objects)
            if className.hasSuffix("Dictionary"),
               let keyRefs = dict["NS.keys"] as? [Any],
               let valueRefs = dict["NS.objects"] as? [Any],
               keyRefs.count == valueRefs.count {
                guard let target = edited as? [String: Any], target.count == keyRefs.count else {
                    throw Failure.invalid("Não é permitido alterar a estrutura do NSDictionary arquivado.")
                }
                for (keyRef, valueRef) in zip(keyRefs, valueRefs) {
                    let key = try archiveResolve(keyRef, objects: objects,
                                                 depth: depth + 1, visiting: [])
                    guard let name = key as? String, let newValue = target[name] else {
                        throw Failure.invalid("Chave NSDictionary não encontrada.")
                    }
                    try archivePatch(valueRef, edited: newValue, objects: &objects,
                                     changed: &changed, depth: depth + 1)
                }
                return
            }
            if className.hasSuffix("Array"), let oldItems = dict["NS.objects"] as? [Any] {
                guard let editedArray = edited as? [Any], editedArray.count == oldItems.count else {
                    throw Failure.invalid("Não é possível adicionar/remover itens diretamente de um NSArray arquivado.")
                }
                for (lhs, rhs) in zip(oldItems, editedArray) {
                    try archivePatch(lhs, edited: rhs, objects: &objects,
                                     changed: &changed, depth: depth + 1)
                }
                return
            }
            if className == "NSDate", let date = edited as? Date {
                // Date is a shared graph class, not a plist Date object in the archived file.
                dict["NS.time"] = date.timeIntervalSinceReferenceDate
                if let ref = objects.indices.first(where: { index in
                    guard let entry = objects[index] as? [String: Any] else { return false }
                    return equal(entry, original)
                }) { objects[ref] = dict }
                return
            }
            guard let editedMap = edited as? [String: Any] else {
                throw Failure.invalid("Classe \(className) precisa continuar sendo um dicionário.")
            }
            let originalKeys = Set(dict.keys.filter { $0 != "$class" })
            let editedKeys = Set(editedMap.keys.filter { $0 != "_class" })
            guard originalKeys == editedKeys else {
                throw Failure.invalid("Não é possível alterar a estrutura de uma classe NSKeyedArchiver; edite valores existentes.")
            }
            for key in originalKeys.sorted() {
                guard let existing = dict[key], let update = editedMap[key] else { continue }
                if uid(existing) != nil {
                    try archivePatch(existing, edited: update, objects: &objects,
                                     changed: &changed, depth: depth + 1)
                } else if let oldNumber = existing as? NSNumber, let newNumber = update as? NSNumber {
                    if !equal(oldNumber, newNumber) { dict[key] = newNumber }
                } else if !equal(existing, update) {
                    dict[key] = update
                }
            }
            if let index = objects.indices.first(where: { i in equal(objects[i], original) }) {
                objects[index] = dict
            }
            return
        }
        if !equal(original, edited) {
            // Scalar inside an object table is patched by the outer UID reference.
        }
    }
}
