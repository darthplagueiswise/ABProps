import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Single-pane source editor. The document is always complete normalized XML,
/// not a key-by-key browser. Import -> decode layers -> edit -> recode envelopes -> save.
struct UniversalPlistEditorView: View {
    @State private var document = PlistTextDocument()
    @State private var importing = false
    @State private var showSearch = false
    @State private var search = ""
    @State private var jump: SourceJump?
    @State private var selectionSerial = 0
    @State private var searchDirection = 1
    @Namespace private var searchGlass
    @FocusState private var searchFocused: Bool

    private var loaded: Bool { document.rawOriginal != nil }

    var body: some View {
        VStack(spacing: 0) {
            navigationControls

            if loaded {
                XMLSourceEditor(
                    text: Binding(
                        get: { document.text },
                        set: { document.markEdited($0) }
                    ),
                    jump: jump,
                    onEdit: { document.markEdited($0) }
                )
                .ignoresSafeArea(.keyboard, edges: .bottom)

                statusBar
            } else {
                emptyState
            }
        }
        .background(Color(red: 0.060, green: 0.066, blue: 0.082))
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.item, .data, .propertyList, .json, .text],
                      allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                try document.open(Data(contentsOf: url), named: url.lastPathComponent, sourceURL: url)
                search = ""
                jump = nil
                showSearch = false
            } catch { document.error = error.localizedDescription }
        }
        .alert("Operação interrompida", isPresented: Binding(
            get: { document.error != nil },
            set: { if !$0 { document.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(document.error ?? "")
        }
        .overlay(alignment: .bottom) {
            if let notice = document.notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 55)
                    .onTapGesture { document.notice = nil }
            }
        }
    }

    @ViewBuilder
    private var navigationControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Plist Editor")
                        .font(.title3.weight(.bold))
                    Text(loaded ? document.fileName : "Conversor universal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                GlassEffectContainer(spacing: 9) {
                    HStack(spacing: 9) {
                        Button { importing = true } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 42, height: 44)
                        }
                        .accessibilityLabel("Importar")
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button { save() } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 19))
                                .frame(width: 42, height: 44)
                        }
                        .disabled(!loaded || !document.dirty)
                        .accessibilityLabel("Salvar alterações no original")
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Menu {
                            Section("Exportar arquivo") {
                                ForEach(PlistTextDocument.Output.allCases) { option in
                                    Button(option.rawValue) { export(option) }
                                }
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 19))
                                .frame(width: 42, height: 44)
                        }
                        .disabled(!loaded)
                        .accessibilityLabel("Exportar formatos")
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
            }

            searchControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var searchControls: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Encontrar texto no XML", text: $search)
                            .focused($searchFocused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { navigateMatch(forward: true) }
                            .accessibilityLabel("Buscar dentro do XML completo")

                        if !search.isEmpty {
                            Button {
                                search = ""
                                jump = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityLabel("Limpar busca")
                        }
                    }
                    .padding(.horizontal, 15)
                    .frame(height: 44)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("search-morph", in: searchGlass)

                    Button { navigateMatch(forward: false) } label: {
                        Image(systemName: "chevron.up").frame(width: 25, height: 42)
                    }
                    .disabled(search.isEmpty)
                    .accessibilityLabel("Ocorrência anterior")
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button { navigateMatch(forward: true) } label: {
                        Image(systemName: "chevron.down").frame(width: 25, height: 42)
                    }
                    .disabled(search.isEmpty)
                    .accessibilityLabel("Próxima ocorrência")
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button {
                        withAnimation(.smooth(duration: 0.38)) { showSearch = false }
                        searchFocused = false
                        search = ""
                        jump = nil
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 42)
                    }
                    .accessibilityLabel("Fechar busca")
                    .glassEffect(.regular.interactive(), in: .circle)
                } else {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.smooth(duration: 0.38)) { showSearch = true }
                        searchFocused = true
                    } label: {
                        Label("Buscar", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 17)
                            .frame(height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("search-morph", in: searchGlass)
                    .disabled(!loaded)
                }
            }
            .animation(.smooth(duration: 0.38), value: showSearch)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.green)
            Text(document.sourceFormat?.title ?? "XML")
                .lineLimit(1)
            Text("·")
            Text(String(document.text.reduce(into: 1) { count, c in
                if c == "\n" { count += 1 }
            }) + " linhas")
            Spacer()
            Text(document.dirty ? "Não salvo" : "Original")
                .foregroundStyle(document.dirty ? .orange : .secondary)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.cyan)
            VStack(spacing: 8) {
                Text("Abra um arquivo para começar")
                    .font(.title2.weight(.semibold))
                Text("Importe seu plist, JSON ou Base64. O conteúdo interno é decodificado em XML contínuo, editável e reversível.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }
            Button { importing = true } label: {
                Label("Importar arquivo", systemImage: "folder.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 30)
                    .frame(height: 52)
            }
            .buttonStyle(.glassProminent)
            Spacer()
            Text("Nenhum ABProps ou arquivo de usuário é pré-carregado")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
    }

    private func navigateMatch(forward: Bool) {
        guard !search.isEmpty else { return }
        let source = document.text as NSString
        let fullLength = source.length
        let start: Int
        if let previous = jump, previous.offset + previous.length <= fullLength {
            start = forward ? previous.offset + max(previous.length, 1) : previous.offset
        } else {
            start = forward ? 0 : fullLength
        }

        let candidate: NSRange
        if forward {
            let remainder = NSRange(location: min(start, fullLength),
                                    length: fullLength - min(start, fullLength))
            let hit = source.range(of: search, options: [.caseInsensitive], range: remainder)
            candidate = hit.location == NSNotFound ?
                source.range(of: search, options: [.caseInsensitive],
                             range: NSRange(location: 0, length: min(start, fullLength))) : hit
        } else {
            let before = NSRange(location: 0, length: min(start, fullLength))
            let hit = source.range(of: search, options: [.caseInsensitive, .backwards], range: before)
            candidate = hit.location == NSNotFound ?
                source.range(of: search, options: [.caseInsensitive, .backwards],
                             range: NSRange(location: min(start, fullLength),
                                            length: fullLength - min(start, fullLength))) : hit
        }

        guard candidate.location != NSNotFound else {
            document.notice = "Nenhuma correspondência para: " + search
            return
        }
        selectionSerial += 1
        jump = SourceJump(offset: candidate.location,
                          length: candidate.length,
                          serial: selectionSerial)
        searchFocused = false
    }

    private func save() {
        do { try document.save() }
        catch { document.error = error.localizedDescription }
    }

    private func export(_ option: PlistTextDocument.Output) {
        do {
            let name = document.outputName(for: option)
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try document.output(option).write(to: destination, options: [.atomic])
            FileShare.present(destination)
        } catch { document.error = error.localizedDescription }
    }
}
