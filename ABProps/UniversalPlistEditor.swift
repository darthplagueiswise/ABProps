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
            compactToolbar
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                } else {
                    emptyState
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(Color(red: 0.060, green: 0.066, blue: 0.082))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let document = workspace.current {
                bottomGlassToolbar(document)
                    .padding(.horizontal, 12)
                    .padding(.top, 5)
                    .padding(.bottom, 4)
            }
        }
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
                    .glassEffect(.regular, in: .capsule)
                    .onTapGesture { workspace.notice = nil }
                    .padding(.bottom, 68)
            }
        }
    }

    // Compact one-line top chrome. Search is in the floating bottom dock so
    // it never consumes a second full-height toolbar row.
    private var compactToolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Plist Universal")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(workspace.current?.title ?? "Editor XML")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GlassEffectContainer(spacing: 5) {
                HStack(spacing: 5) {
                    Button { importing = true } label: {
                        Image(systemName: "folder.badge.plus")
                            .frame(width: 33, height: 38)
                    }
                    .accessibilityLabel("Importar arquivos")
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button { save() } label: {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 33, height: 38)
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
                            .frame(width: 33, height: 38)
                    }
                    .disabled(workspace.current == nil)
                    .accessibilityLabel("Exportar arquivo")
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button { showTypography = true } label: {
                        Image(systemName: "textformat.size")
                            .frame(width: 33, height: 38)
                    }
                    .accessibilityLabel("Ajustar tamanho da fonte")
                    .glassEffect(.regular.interactive(), in: .circle)
                    .popover(isPresented: $showTypography, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tamanho do código")
                                .font(.headline)
                            HStack(spacing: 8) {
                                Image(systemName: "textformat.size.smaller")
                                Slider(value: $fontSize, in: 9...22, step: 1)
                                Image(systemName: "textformat.size.larger")
                            }
                            Text("\(Int(fontSize)) pt · fonte monoespaçada")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Menor") { fontSize = max(9, fontSize - 1) }
                                Spacer()
                                Button("Restaurar") { fontSize = 12 }
                                Spacer()
                                Button("Maior") { fontSize = min(22, fontSize + 1) }
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(18)
                        .frame(width: 296)
                        .presentationCompactAdaptation(.popover)
                    }
                }
                .font(.system(size: 16, weight: .regular))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func bottomGlassToolbar(_ document: PlistWorkspace.Document) -> some View {
        GlassEffectContainer(spacing: 7) {
            HStack(spacing: 7) {
                if searching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Buscar no XML", text: $searchText)
                            .focused($searchFocused)
                            .font(.subheadline)
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
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 43)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("search", in: searchNamespace)

                    Button { searchNext(false) } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 28, height: 42)
                    }
                    .disabled(searchText.isEmpty)
                    .accessibilityLabel("Resultado anterior")
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button { searchNext(true) } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 28, height: 42)
                    }
                    .disabled(searchText.isEmpty)
                    .accessibilityLabel("Próximo resultado")
                    .glassEffect(.regular.interactive(), in: .circle)

                    Button {
                        withAnimation(.smooth(duration: 0.32)) { searching = false }
                        searchFocused = false
                        searchText = ""
                        jump = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 42)
                    }
                    .accessibilityLabel("Fechar pesquisa")
                    .glassEffect(.regular.interactive(), in: .circle)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.green)
                        Text(document.encoding.title)
                            .lineLimit(1)
                        Text("·")
                        Text("\(document.lines) linhas")
                            .lineLimit(1)
                        Spacer(minLength: 3)
                        Text("\(Int(fontSize))pt")
                        Text(document.isDirty ? "Editado" : "Original")
                            .foregroundStyle(document.isDirty ? .orange : .secondary)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(height: 43)
                    .glassEffect(.regular, in: .capsule)

                    Button {
                        withAnimation(.smooth(duration: 0.32)) { searching = true }
                        searchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: 35, height: 42)
                    }
                    .accessibilityLabel("Buscar no arquivo")
                    .glassEffect(.regular.interactive(), in: .circle)
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
        .padding(.vertical, 3)
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
