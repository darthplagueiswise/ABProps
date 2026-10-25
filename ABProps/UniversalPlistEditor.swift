import SwiftUI
import UniformTypeIdentifiers
import Observation

/// A separate document workspace; existing ABProps, MobileConfig and framework tools remain intact.
struct UniversalPlistEditorView: View {
    @State private var document = UniversalDocumentStore()
    @State private var isImporting = false
    @State private var search = ""
    @State private var selectedEdit: UniversalEditTarget?

    var body: some View {
        NavigationStack {
            Group {
                if document.root == nil {
                    landing
                } else {
                    UniversalTreeView(
                        document: document,
                        path: [],
                        search: search,
                        onEdit: { selectedEdit = UniversalEditTarget(path: $0) }
                    )
                }
            }
            .navigationTitle("Plist Universal")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Importar", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Abrir plist, JSON ou Base64")

                    if document.root != nil {
                        Button {
                            document.undo()
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .disabled(!document.canUndo)
                        .accessibilityLabel("Desfazer alteração")

                        Menu {
                            ForEach(UniversalExport.allCases) { format in
                                Button(format.rawValue) { save(format) }
                            }
                        } label: {
                            Label("Exportar", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Filtrar chaves nesta pasta")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item, .propertyList, .json, .data, .plainText],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                try document.open(Data(contentsOf: url), name: url.lastPathComponent)
                search = ""
            } catch {
                document.error = error.localizedDescription
            }
        }
        .sheet(item: $selectedEdit) { item in
            UniversalScalarEditor(document: document, path: item.path)
        }
        .alert("Erro no documento", isPresented: Binding(
            get: { document.error != nil },
            set: { if !$0 { document.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(document.error ?? "")
        }
    }

    @ViewBuilder
    private var landing: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "curlybraces.square.fill")
                    .font(.system(size: 60, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Um editor. Todos os valores.")
                        .font(.title2.bold())
                    Text("Plist XML e binário, JSON, Base64 e arquivos NSKeyedArchiver. Explore os dados completos sem truncar arrays.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 12) {
                        Button {
                            isImporting = true
                        } label: {
                            Label("Selecionar arquivo", systemImage: "doc.badge.plus")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                } else {
                    Button("Selecionar arquivo") { isImporting = true }
                        .buttonStyle(.borderedProminent)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Label("Edição de booleanos, números, datas, dados e textos", systemImage: "pencil.line")
                    Label("Exportação em XML, binário, JSON tipado e Base64", systemImage: "arrow.left.arrow.right")
                    Label("Arquivos originais sem edição preservados byte a byte", systemImage: "checkmark.shield")
                    Label("Grafos NSKeyedArchiver sem instanciar classes desconhecidas", systemImage: "square.stack.3d.up")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .universalGlassCard()
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }

    private func save(_ format: UniversalExport) {
        do {
            let (data, name) = try document.export(format)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic])
            FileShare.present(url)
        } catch {
            document.error = error.localizedDescription
        }
    }
}

private struct UniversalEditTarget: Identifiable {
    let id = UUID()
    let path: [UniversalPathPart]
}

private extension View {
    @ViewBuilder
    func universalGlassCard() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

private struct UniversalTreeView: View {
    let document: UniversalDocumentStore
    let path: [UniversalPathPart]
    let search: String
    let onEdit: ([UniversalPathPart]) -> Void

    var body: some View {
        Group {
            if let value = document.value(at: path) {
                List {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(document.fileName)
                                    .font(.headline)
                                Text(UniversalPlistCodec.kind(value) + " · " +
                                     UniversalPlistCodec.summary(value))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let encoding = document.encoding {
                                    Text(encoding.title + (document.dirty ? " · modificado" : " · original"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.tint)
                        }
                        .padding(.vertical, 4)
                    }

                    Section("Estrutura completa") {
                        ForEach(children(of: value)) { child in
                            if let childValue = document.value(at: child.path) {
                                let expandable = !UniversalPlistCodec.children(childValue, path: child.path).isEmpty
                                if expandable {
                                    NavigationLink {
                                        UniversalTreeView(
                                            document: document,
                                            path: child.path,
                                            search: "",
                                            onEdit: onEdit
                                        )
                                        .navigationTitle(child.title)
                                        .navigationBarTitleDisplayMode(.inline)
                                    } label: {
                                        UniversalNodeLabel(title: child.title, value: childValue)
                                    }
                                    .contextMenu {
                                        if UniversalPlistCodec.editableText(childValue) != nil {
                                            Button("Editar valor bruto", systemImage: "pencil") {
                                                onEdit(child.path)
                                            }
                                        }
                                    }
                                } else {
                                    Button {
                                        onEdit(child.path)
                                    } label: {
                                        UniversalNodeLabel(title: child.title, value: childValue)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(UniversalPlistCodec.editableText(childValue) == nil)
                                }
                            }
                        }
                    } footer: {
                        Text("Todos os elementos estão presentes. A busca filtra apenas a visualização; não modifica o arquivo.")
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ContentUnavailableView("Nó indisponível", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func children(of value: Any) -> [UniversalNodeRef] {
        let all = UniversalPlistCodec.children(value, path: path)
        guard !search.isEmpty else { return all }
        return all.filter {
            $0.title.localizedStandardContains(search) ||
            (document.value(at: $0.path).map {
                UniversalPlistCodec.summary($0).localizedStandardContains(search)
            } ?? false)
        }
    }
}

private struct UniversalNodeLabel: View {
    let title: String
    let value: Any

    private var icon: String {
        if value is [String: Any] { return "curlybraces" }
        if value is [Any] { return "list.number" }
        if value is Data { return "externaldrive" }
        if value is Date { return "calendar" }
        if value is NSNumber { return "number" }
        return "text.alignleft"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(UniversalPlistCodec.summary(value))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Text(UniversalPlistCodec.kind(value))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct UniversalScalarEditor: View {
    let document: UniversalDocumentStore
    let path: [UniversalPathPart]

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var ready = false

    private var previous: Any? { document.value(at: path) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tipo original") {
                    Text(previous.map(UniversalPlistCodec.kind) ?? "Indefinido")
                        .foregroundStyle(.secondary)
                }
                Section("Valor completo") {
                    if let number = previous as? NSNumber,
                       UniversalPlistCodec.kind(number) == "Booleano" {
                        Toggle("Ativado", isOn: Binding(
                            get: { draft == "true" },
                            set: { draft = $0 ? "true" : "false" }
                        ))
                    } else {
                        TextEditor(text: $draft)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if previous is Data {
                        Text("Dados binários são editados como Base64. Nenhum byte é descartado.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if previous is Date {
                        Text("Use uma data ISO 8601 em UTC.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Salvar altera apenas este nó; ao exportar, o restante da estrutura permanece no modelo original.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Editar valor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        do {
                            try document.change(at: path, text: draft)
                            dismiss()
                        } catch {
                            document.error = error.localizedDescription
                        }
                    }
                    .disabled(!ready || previous == nil)
                }
            }
            .onAppear {
                draft = previous.flatMap(UniversalPlistCodec.editableText) ?? ""
                ready = true
            }
        }
        .presentationDetents([.large])
    }
}
