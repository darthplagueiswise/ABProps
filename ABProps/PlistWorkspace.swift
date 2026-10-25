import Foundation
import Observation

/// Imported content is always copied into the app's private Documents workspace.
/// Tabs and unfinished edits survive app termination, including while Files loses access
/// to its original security-scoped URL.
@Observable
@MainActor
final class PlistWorkspace {
    @Observable
    @MainActor
    final class Document: Identifiable {
        let id: UUID
        var title: String
        var text: String
        var source: Data
        let encoding: UniversalEncoding
        var sourceBookmark: Data?
        var isDirty: Bool
        var revision = 0

        init(id: UUID = UUID(), title: String, text: String, source: Data,
             encoding: UniversalEncoding, bookmark: Data?, dirty: Bool = false) {
            self.id = id
            self.title = title
            self.text = text
            self.source = source
            self.encoding = encoding
            self.sourceBookmark = bookmark
            self.isDirty = dirty
        }

        func setText(_ newText: String) {
            guard newText != text else { return }
            text = newText
            isDirty = true
            revision += 1
        }

        var lines: Int { text.reduce(into: 1) { total, character in if character == "\n" { total += 1 } } }
    }

    private struct Record: Codable {
        var id: UUID
        var title: String
        var dirty: Bool
    }

    private struct Index: Codable {
        var selected: UUID?
        var tabs: [Record]
    }

    var documents: [Document] = []
    var selected: UUID?
    var revision = 0
    var notice: String?
    var error: String?

    var current: Document? {
        documents.first(where: { $0.id == selected })
    }

    private let home: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        home = base.appendingPathComponent("UniversalPlistWorkspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        restore()
    }

    func importFile(data: Data, name: String, url: URL?) throws {
        let decoded = try SemanticPlistEngine.open(data)
        let bookmark = try? url?.bookmarkData()
        let doc = Document(title: name, text: decoded.text,
                           source: data, encoding: decoded.kind, bookmark: bookmark)
        documents.append(doc)
        selected = doc.id
        revision += 1
        persist()
        notice = "\(name) importado"
    }

    func setSelected(_ id: UUID) {
        guard documents.contains(where: { $0.id == id }) else { return }
        selected = id
        revision += 1
        persist()
    }

    func close(_ id: UUID) {
        documents.removeAll(where: { $0.id == id })
        if selected == id { selected = documents.last?.id }
        try? FileManager.default.removeItem(at: folder(for: id))
        revision += 1
        persist()
    }

    func textChanged(_ value: String, for id: UUID) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        document.setText(value)
        revision += 1
    }

    func validateCurrent() throws {
        guard let document = current else { throw UniversalError.invalidFormat }
        _ = try SemanticPlistEngine.save(document.text, original: document.source,
                                        kind: document.encoding)
    }

    /// Save always commits to our persistent local workspace. If the Files bookmark
    /// resolves and grants write access, write through to the original as well.
    func saveCurrent() throws {
        guard let document = current else { throw UniversalError.invalidFormat }
        let output: Data = document.isDirty ?
            try SemanticPlistEngine.save(document.text, original: document.source,
                                         kind: document.encoding) : document.source
        persist()
        var savedOriginal = false

        if let data = document.sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var outerError: NSError?
                var innerError: Error?
                coordinator.coordinate(writingItemAt: url, options: .forReplacing,
                                       error: &outerError) { destination in
                    do { try output.write(to: destination, options: [.atomic]) }
                    catch { innerError = error }
                }
                savedOriginal = outerError == nil && innerError == nil
            }
        }

        if savedOriginal {
            document.source = output
            document.isDirty = false
            persist()
            notice = "Salvo no documento original e na sessão."
        } else {
            notice = "Alterações guardadas na sessão. Exporte para atualizar o arquivo externo."
        }
    }

    enum ExportMode: String, CaseIterable, Identifiable {
        case original = "Formato original"
        case xml = "XML legível"
        case binary = "Plist binário"
        case json = "JSON tipado"
        case base64Original = "Base64 do formato original"
        case base64Binary = "Base64 de plist binário"
        case base64JSON = "Base64 de JSON"
        var id: String { rawValue }
    }

    func exportCurrent(_ mode: ExportMode) throws -> (Data, String) {
        guard let doc = current else { throw UniversalError.invalidFormat }
        let result: Data
        let extensionName: String
        switch mode {
        case .original:
            result = doc.isDirty ?
                try SemanticPlistEngine.save(doc.text, original: doc.source, kind: doc.encoding) :
                doc.source
            extensionName = URL(fileURLWithPath: doc.title).pathExtension.isEmpty ?
                "plist" : URL(fileURLWithPath: doc.title).pathExtension
        case .xml:
            _ = try SemanticPlistEngine.parseXML(doc.text)
            result = Data(doc.text.utf8)
            extensionName = "plist"
        case .binary:
            result = try SemanticPlistEngine.export(doc.text, original: doc.source,
                                                     kind: doc.encoding, as: .binary)
            extensionName = "plist"
        case .json:
            result = try SemanticPlistEngine.export(doc.text, original: doc.source,
                                                     kind: doc.encoding, as: .json)
            extensionName = "json"
        case .base64Original:
            let raw = doc.isDirty ?
                try SemanticPlistEngine.save(doc.text, original: doc.source, kind: doc.encoding) :
                doc.source
            if case .base64 = doc.encoding { result = raw }
            else { result = Data(raw.base64EncodedString().utf8) }
            extensionName = "b64"
        case .base64Binary:
            result = try SemanticPlistEngine.export(doc.text, original: doc.source,
                                                     kind: doc.encoding, as: .base64(.binary))
            extensionName = "b64"
        case .base64JSON:
            result = try SemanticPlistEngine.export(doc.text, original: doc.source,
                                                     kind: doc.encoding, as: .base64(.json))
            extensionName = "b64"
        }
        let base = URL(fileURLWithPath: doc.title).deletingPathExtension().lastPathComponent
        return (result, base + "-edited." + extensionName)
    }

    private func folder(for id: UUID) -> URL {
        home.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Explicit persistence also makes drafts available after iOS kills the process.
    func persist() {
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for doc in documents {
                let folder = folder(for: doc.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try doc.source.write(to: folder.appendingPathComponent("source.bin"), options: [.atomic])
                try Data(doc.text.utf8).write(to: folder.appendingPathComponent("draft.xml"), options: [.atomic])
                let bookmark = folder.appendingPathComponent("bookmark.bin")
                if let data = doc.sourceBookmark {
                    try data.write(to: bookmark, options: [.atomic])
                }
            }
            let index = Index(selected: selected, tabs: documents.map {
                Record(id: $0.id, title: $0.title, dirty: $0.isDirty)
            })
            let metadata = try JSONEncoder().encode(index)
            try metadata.write(to: home.appendingPathComponent("tabs.json"), options: [.atomic])
            error = nil
        } catch {
            self.error = "Não foi possível persistir os documentos: " + error.localizedDescription
        }
    }

    private func restore() {
        let dataURL = home.appendingPathComponent("tabs.json")
        guard let data = try? Data(contentsOf: dataURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        var restored: [Document] = []
        for entry in index.tabs {
            let dir = folder(for: entry.id)
            guard let source = try? Data(contentsOf: dir.appendingPathComponent("source.bin")),
                  let xml = try? String(contentsOf: dir.appendingPathComponent("draft.xml"), encoding: .utf8),
                  let decoded = try? UniversalPlistCodec.decode(source) else { continue }
            let bookmark = try? Data(contentsOf: dir.appendingPathComponent("bookmark.bin"))
            restored.append(Document(id: entry.id, title: entry.title,
                                     text: xml, source: source, encoding: decoded.encoding,
                                     bookmark: bookmark, dirty: entry.dirty))
        }
        documents = restored
        selected = restored.contains(where: { $0.id == index.selected }) ?
            index.selected : restored.first?.id
    }
}
