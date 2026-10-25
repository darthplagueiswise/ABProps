import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Source-code workspace with native Liquid Glass chrome.
/// Document content itself is opaque and deliberately does not use glass:
/// readable, adjustable monospaced code and full scrolling are the priority.
struct UniversalPlistEditorView: View {
    @State private var workspace = PlistWorkspace()
    @AppStorage("universal.plist.fontSize") private var fontSize = 12.0
    @Environment(\.scenePhase) private var scenePhase
    @State private var showTypography = false
    @State private var importing = false
    @State private var searching = false
    @State private var searchText = ""
    @State private var jump: SourceJump?
    @State private var matchSerial = 0
    @Namespace private var searchNamespace
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if workspace.current != nil { tabStrip }
            Group {
                if let document = workspace.current {
                    XMLSourceEditor(
                        text: Binding(
                            get: { document.text },
                            set: { workspace.textChanged($0, for: document.id) }
                        ),
                        jump: jump,
                        fontSize: fontSize,
                        onEdit: { workspace.textChanged($0, for: document.id) }
                    )
                    .id(document.id)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    statusLine(document)
                } else {
                    emptyState
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(red: 0.060, green: 0.066, blue: 0.082))
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item, .data, .propertyList, .json, .plainText],
                      allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    try workspace.importFile(data: Data(contentsOf: url),
                                              name: url.lastPathComponent, url: url)
                }
            } catch { workspace.error = error.localizedDescription }
        }
        .alert("Erro", isPresented: Binding(
            get: { workspace.error != nil },
            set: { if !$0 { workspace.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspace.error ?? "")
        }
        .task(id: workspace.revision) {
            // Drafts are written to Application Support after edits settle.
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            workspace.persist()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { workspace.persist() }
        }
        .onChange(of: workspace.selected) { _, _ in
            jump = nil
            searchText = ""
            searching = false
        }
        .overlay(alignment: .bottom) {
            if let notice = workspace.notice {
                Text(notice)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.thickMaterial, in: Capsule())
                    .onTapGesture { workspace.notice = nil }
                    .padding(.bottom, 44)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Plist Editor")
                        .font(.headline.weight(.semibold))
                    Text(workspace.current?.title ?? "Nenhum documento")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button { importing = true } label: {
                            Image(systemName: "folder.badge.plus")
                                .frame(width: 37, height: 40)
                        }
                        .accessibilityLabel("Importar arquivos")
                        .glassEffect(.regular.interactive(), in: .circle)

                        Button { save() } label: {
                            Image(systemName: "square.and.arrow.down")
                                .frame(width: 37, height: 40)
                        }
                        .disabled(workspace.current == nil)
                        .accessibilityLabel("Salvar arquivo")
                        .glassEffect(.regular.interactive(), in: .circle)

                        Menu {
                            Section("Exportar documento") {
                                ForEach(PlistWorkspace.ExportMode.allCases) { mode in
                                    Button(mode.rawValue) { export(mode) }
                                }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 37, height: 40)
                        }
                        .disabled(workspace.current == nil)
                        .accessibilityLabel("Exportar arquivo")
                        .glassEffect(.regular.interactive(), in: .circle)

                        Button { showTypography = true } label: {
                            Image(systemName: "textformat.size")
                                .frame(width: 37, height: 40)
                        }
                        .accessibilityLabel("Ajustar tamanho da fonte")
                        .glassEffect(.regular.interactive(), in: .circle)
                        .popover(isPresented: $showTypography, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Tamanho do texto")
                                    .font(.headline)
                                HStack(spacing: 10) {
                                    Image(systemName: "textformat.size.smaller")
                                    Slider(value: $fontSize, in: 9...22, step: 1)
                                        .accessibilityLabel("Tamanho da fonte")
                                    Image(systemName: "textformat.size.larger")
                                }
                                Text("\(Int(fontSize)) pt — Monoespaçada")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Reduzir") { fontSize = max(9, fontSize - 1) }
                                    Spacer()
                                    Button("Restaurar") { fontSize = 12 }
                                    Spacer()
                                    Button("Aumentar") { fontSize = min(22, fontSize + 1) }
                                }
                                .buttonStyle(.glass)
                            }
                            .padding(20)
                            .frame(width: 300)
                            .presentationCompactAdaptation(.popover)
                        }
                    }
                }
            }
            searchBar
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var searchBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if searching {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Encontrar no texto XML", text: $searchText)
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { searchNext(true) }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                jump = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .accessibilityLabel("Limpar pesquisa")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 43)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("search", in: searchNamespace)
                    Button { searchNext(false) } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 30, height: 42)
                    }
                    .disabled(searchText.isEmpty)
                    .accessibilityLabel("Anterior")
                    .glassEffect(.regular.interactive(), in: .circle)
                    Button { searchNext(true) } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 30, height: 42)
                    }
                    .disabled(searchText.isEmpty)
                    .accessibilityLabel("Próximo")
                    .glassEffect(.regular.interactive(), in: .circle)
                    Button {
                        withAnimation(.smooth(duration: 0.32)) { searching = false }
                        searchText = ""
                        searchFocused = false
                        jump = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 30, height: 42)
                    }
                    .accessibilityLabel("Fechar pesquisa")
                    .glassEffect(.regular.interactive(), in: .circle)
                } else {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.smooth(duration: 0.32)) { searching = true }
                        searchFocused = true
                    } label: {
                        Label("Buscar", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .frame(height: 43)
                    }
                    .disabled(workspace.current == nil)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("search", in: searchNamespace)
                }
            }
            .animation(.smooth(duration: 0.32), value: searching)
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(workspace.documents) { item in
                        HStack(spacing: 7) {
                            Button {
                                workspace.setSelected(item.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "doc.text")
                                        .font(.caption)
                                    Text(item.title)
                                        .font(.caption.weight(item.id == workspace.selected ? .semibold : .regular))
                                        .lineLimit(1)
                                        .frame(maxWidth: 168)
                                    if item.isDirty {
                                        Circle()
                                            .fill(.orange)
                                            .frame(width: 5, height: 5)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Abrir aba \(item.title)")
                            Button {
                                workspace.close(item.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .frame(width: 20, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Fechar aba \(item.title)")
                        }
                        .padding(.horizontal, 11)
                        .frame(height: 36)
                        .glassEffect(
                            .regular.tint(item.id == workspace.selected ?
                                Color.accentColor.opacity(0.24) : Color.clear).interactive(),
                            in: .capsule
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func statusLine(_ document: PlistWorkspace.Document) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text(document.encoding.title)
            Text("·")
            Text("\(document.lines) linhas")
            Spacer()
            Text("\(Int(fontSize)) pt")
            Text("·")
            Text(document.isDirty ? "Editado" : "Original")
                .foregroundStyle(document.isDirty ? .orange : .secondary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.cyan)
            VStack(spacing: 8) {
                Text("Editor XML universal")
                    .font(.title2.weight(.semibold))
                Text("Abra plist XML, binário, JSON ou Base64. O conteúdo reconhecido é decodificado automaticamente sem expor envelopes e tabelas UID.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Button { importing = true } label: {
                Label("Importar documentos", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 22)
                    .frame(height: 52)
            }
            .buttonStyle(.glassProminent)
            Spacer()
            Text("Seus documentos ficam disponíveis em abas mesmo após fechar o app.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func searchNext(_ forward: Bool) {
        guard let doc = workspace.current, !searchText.isEmpty else { return }
        let source = doc.text as NSString
        let length = source.length
        let beginning: Int
        if let previous = jump, previous.offset + previous.length <= length {
            beginning = forward ? previous.offset + max(previous.length, 1) : previous.offset
        } else {
            beginning = forward ? 0 : length
        }
        let start = min(beginning, length)
        let range: NSRange
        if forward {
            let match = source.range(of: searchText, options: .caseInsensitive,
                                     range: NSRange(location: start, length: length - start))
            range = match.location == NSNotFound ?
                source.range(of: searchText, options: .caseInsensitive,
                             range: NSRange(location: 0, length: start)) : match
        } else {
            let match = source.range(of: searchText, options: [.caseInsensitive, .backwards],
                                     range: NSRange(location: 0, length: start))
            range = match.location == NSNotFound ?
                source.range(of: searchText, options: [.caseInsensitive, .backwards],
                             range: NSRange(location: start, length: length - start)) : match
        }
        if range.location == NSNotFound {
            workspace.notice = "Nenhuma ocorrência de: " + searchText
        } else {
            matchSerial += 1
            jump = SourceJump(offset: range.location, length: range.length,
                              serial: matchSerial)
            searchFocused = false
        }
    }

    private func save() {
        do { try workspace.saveCurrent() }
        catch { workspace.error = error.localizedDescription }
    }

    private func export(_ mode: PlistWorkspace.ExportMode) {
        do {
            let (data, name) = try workspace.exportCurrent(mode)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: destination, options: [.atomic])
            FileShare.present(destination)
        } catch { workspace.error = error.localizedDescription }
    }
}
