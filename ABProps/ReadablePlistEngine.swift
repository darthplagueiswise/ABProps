import Foundation
import CoreFoundation
import Observation

/// The on-screen XML is a loss-aware interchange representation.
/// Embedded JSON and plist containers are expanded inside explicit, reversible envelopes.
/// Export folds those envelopes back into precisely the original carrier (Data / string / Base64).
enum ReadablePlistEngine {
    private static let signature = "__PLIST_EDITOR_ENVELOPE_5CB43AA2__"
    private static let version = "1"
    private static let maxDepth = 24
    private static let maxInputSize = 128 * 1024 * 1024

    enum ConversionError: LocalizedError {
        case tooLarge, damaged(String), unsupported(String)
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Arquivo maior que 128 MB; proteja a memória do iPhone."
            case .damaged(let reason): return "O texto XML não pôde ser reconstruído: " + reason
            case .unsupported(let reason): return "Conversão não reversível: " + reason
            }
        }
    }

    struct Loaded {
        let xml: String
        let original: Data
        let encoding: UniversalEncoding
        let statistics: Statistics
    }

    struct Statistics {
        var decodedContainers = 0
        var dataBlocks = 0
        var strings = 0
        var archiveGraphs = 0
        var arrayItems = 0
    }

    static func open(_ bytes: Data) throws -> Loaded {
        guard bytes.count <= maxInputSize else { throw ConversionError.tooLarge }
        let decoded = try UniversalPlistCodec.decode(bytes)
        var info = Statistics()
        let expanded = expand(decoded.object, depth: 0, stats: &info)
        let output = try PropertyListSerialization.data(
            fromPropertyList: expanded, format: .xml, options: 0
        )
        guard let xml = String(data: output, encoding: .utf8) else {
            throw ConversionError.damaged("não foi possível gerar XML UTF-8")
        }
        return Loaded(xml: xml, original: bytes, encoding: decoded.encoding, statistics: info)
    }

    private static func container(_ encoding: String, value: Any) -> [String: Any] {
        [signature: version, "envelope": encoding, "decoded_value": value]
    }

    private static func originalKind(_ object: Any) -> String {
        if object is Data { return "data" }
        return "string"
    }

    private static func expand(_ object: Any, depth: Int, stats: inout Statistics) -> Any {
        guard depth <= maxDepth else { return object }
        if let dict = object as? [String: Any] {
            if dict["$archiver"] as? String == "NSKeyedArchiver" {
                stats.archiveGraphs += 1
            }
            var normalized: [String: Any] = [:]
            for (k, v) in dict {
                normalized[k] = expand(v, depth: depth + 1, stats: &stats)
            }
            return normalized
        }
        if let array = object as? [Any] {
            stats.arrayItems += array.count
            return array.map { expand($0, depth: depth + 1, stats: &stats) }
        }
        if object is Data { stats.dataBlocks += 1 }
        if object is String { stats.strings += 1 }
        guard let inner = decodeEmbedded(object), depth < maxDepth else { return object }
        stats.decodedContainers += 1
        let value = expand(inner.object, depth: depth + 1, stats: &stats)
        return container(originalKind(object) + "|" + token(inner.encoding), value: value)
    }

    private static func decodeEmbedded(_ input: Any) -> UniversalPlistCodec.Decoded? {
        if let data = input as? Data {
            // Only reinterpret positively identified structured payloads.
            if data.starts(with: Data("bplist00".utf8)) ||
               data.starts(with: Data("<?xml".utf8)) ||
               data.starts(with: Data("<plist".utf8)) {
                return try? UniversalPlistCodec.decode(data)
            }
            if isJSONBytes(data) { return try? UniversalPlistCodec.decode(data) }
            if let string = String(data: data, encoding: .utf8),
               isLikelyBase64(string) {
                return try? UniversalPlistCodec.decode(data)
            }
        }
        if let text = input as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ||
               trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") ||
               isLikelyBase64(trimmed) {
                return try? UniversalPlistCodec.decode(Data(text.utf8))
            }
        }
        return nil
    }

    private static func isJSONBytes(_ data: Data) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("{") || s.hasPrefix("[")
    }

    private static func isLikelyBase64(_ input: String) -> Bool {
        let compact = input.filter { !$0.isWhitespace }
        guard compact.count >= 16, compact.count % 4 == 0 else { return false }
        let valid = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return compact.unicodeScalars.allSatisfy { valid.contains($0) }
    }

    private static func token(_ encoding: UniversalEncoding) -> String {
        switch encoding {
        case .xml: return "xml"
        case .binary: return "binary"
        case .json: return "json"
        case .base64(let nested): return "base64+" + token(nested)
        }
    }

    private static func encoding(_ token: String) throws -> UniversalEncoding {
        if token.hasPrefix("base64+") {
            return .base64(try encoding(String(token.dropFirst(7))))
        }
        switch token {
        case "xml": return .xml
        case "binary": return .binary
        case "json": return .json
        default: throw ConversionError.damaged("envelope desconhecido: " + token)
        }
    }

    static func normalizedObject(from text: String) throws -> Any {
        guard let data = text.data(using: .utf8) else {
            throw ConversionError.damaged("UTF-8 inválido")
        }
        do {
            return try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ConversionError.damaged(error.localizedDescription)
        }
    }

    static func reconstruct(_ text: String, originalFormat: UniversalEncoding) throws -> Data {
        let logical = try normalizedObject(from: text)
        let folded = try fold(logical, depth: 0)
        return try UniversalPlistCodec.encode(folded, as: originalFormat)
    }

    static func converted(_ text: String, format: UniversalEncoding) throws -> Data {
        let logical = try normalizedObject(from: text)
        return try UniversalPlistCodec.encode(try fold(logical, depth: 0), as: format)
    }

    private static func fold(_ object: Any, depth: Int) throws -> Any {
        guard depth <= maxDepth else { throw ConversionError.damaged("profundidade de codificação excedida") }
        if let dict = object as? [String: Any] {
            if dict[signature] as? String == version,
               let envelope = dict["envelope"] as? String,
               let wrapped = dict["decoded_value"] {
                let parts = envelope.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      (parts[0] == "data" || parts[0] == "string") else {
                    throw ConversionError.damaged("envelope adulterado")
                }
                let value = try fold(wrapped, depth: depth + 1)
                let bytes = try UniversalPlistCodec.encode(value, as: encoding(String(parts[1])))
                if parts[0] == "data" { return bytes }
                guard let string = String(data: bytes, encoding: .utf8) else {
                    throw ConversionError.unsupported("payload textual em encoding não UTF-8")
                }
                return string
            }
            var original: [String: Any] = [:]
            for (k, v) in dict { original[k] = try fold(v, depth: depth + 1) }
            return original
        }
        if let list = object as? [Any] {
            return try list.map { try fold($0, depth: depth + 1) }
        }
        return object
    }
}

@Observable
@MainActor
final class PlistTextDocument {
    var text = ""
    var fileName = ""
    var fileURL: URL?
    var sourceFormat: UniversalEncoding?
    var rawOriginal: Data?
    var info = ReadablePlistEngine.Statistics()
    var dirty = false
    var error: String?
    var notice: String?
    var revision = 0

    func open(_ data: Data, named: String, sourceURL: URL? = nil) throws {
        let loaded = try ReadablePlistEngine.open(data)
        text = loaded.xml
        fileName = named
        fileURL = sourceURL
        sourceFormat = loaded.encoding
        rawOriginal = data
        info = loaded.statistics
        dirty = false
        error = nil
        notice = nil
        revision += 1
    }

    func markEdited(_ changed: String) {
        guard changed != text else { return }
        text = changed
        dirty = true
        revision += 1
    }

    func validate() throws {
        guard let format = sourceFormat else { throw UniversalError.invalidFormat }
        _ = try ReadablePlistEngine.reconstruct(text, originalFormat: format)
    }

    /// Write atomically to the original file. If the Files provider lacks write access, use Export.
    func save() throws {
        guard let target = fileURL else {
            throw ReadablePlistEngine.ConversionError.unsupported("nenhum arquivo de origem; use Exportar")
        }
        let payload = try output(.original)
        let access = target.startAccessingSecurityScopedResource()
        defer { if access { target.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: target, options: .forReplacing,
                               error: &coordinationError) { url in
            do { try payload.write(to: url, options: [.atomic]) }
            catch { writeError = error }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
        rawOriginal = payload
        dirty = false
        notice = "Salvo em " + fileName
    }

    enum Output: String, CaseIterable, Identifiable {
        case original = "Formato original"
        case normalized = "XML legível"
        case xml = "XML reconstituído"
        case binary = "Plist binário"
        case json = "JSON tipado"
        case originalBase64 = "Base64 original"
        case binaryBase64 = "Base64 binário"
        case jsonBase64 = "Base64 JSON"
        var id: String { rawValue }
    }

    func output(_ option: Output) throws -> Data {
        guard let format = sourceFormat, let original = rawOriginal else {
            throw UniversalError.invalidFormat
        }
        switch option {
        case .original:
            return dirty ? try ReadablePlistEngine.reconstruct(text, originalFormat: format) : original
        case .normalized:
            _ = try ReadablePlistEngine.normalizedObject(from: text)
            return Data(text.utf8)
        case .xml: return try ReadablePlistEngine.converted(text, format: .xml)
        case .binary: return try ReadablePlistEngine.converted(text, format: .binary)
        case .json: return try ReadablePlistEngine.converted(text, format: .json)
        case .originalBase64:
            let encoded = dirty ? try ReadablePlistEngine.reconstruct(text, originalFormat: format) : original
            // If input is already Base64, return original rather than double-encoding it.
            if case .base64 = format { return encoded }
            return Data(encoded.base64EncodedString().utf8)
        case .binaryBase64: return try ReadablePlistEngine.converted(text, format: .base64(.binary))
        case .jsonBase64: return try ReadablePlistEngine.converted(text, format: .base64(.json))
        }
    }

    func outputName(for option: Output) -> String {
        let stripped = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let base = stripped.isEmpty ? "Plist" : stripped
        let ext: String
        switch option {
        case .normalized, .xml: ext = "plist"
        case .binary: ext = "plist"
        case .json: ext = "json"
        case .original:
            ext = URL(fileURLWithPath: fileName).pathExtension.isEmpty ?
                "plist" : URL(fileURLWithPath: fileName).pathExtension
        case .originalBase64, .binaryBase64, .jsonBase64: ext = "b64"
        }
        return base + (option == .original ? "" : "-export") + "." + ext
    }
}
