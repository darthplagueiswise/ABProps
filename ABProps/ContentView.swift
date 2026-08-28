import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var pickingPlist = false
    @State private var pickingBinary = false
    @State private var pickingJSON = false
    @State private var pickingMC = false

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            HomeView(
                onPlist: { pickingPlist = true },
                onBinary: { pickingBinary = true },
                onJSON: { pickingJSON = true },
                onMC: { pickingMC = true },
                onShareNames: { share(name: "abprops-web.json") { try store.exportNames() } }
            )
            .navigationTitle("ABProps")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: AppScreen.self) { screen in
                switch screen {
                case .home:
                    EmptyView()
                case .flags:
                    FlagsView(onShare: { share(name: store.plistName.isEmpty ? "abp.plist" : store.plistName) { try store.exportPlist() } })
                case .mobileConfig:
                    MCView(
                        onShareMapping: { share(name: "id_name_mapping.json") { try store.exportMapping() } },
                        onShareOverrides: { share(name: "mc_overrides.json") { try store.exportOverrides() } }
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $pickingPlist, allowedContentTypes: [.item, .propertyList, .data, .json, .text], allowsMultipleSelection: true) { ingestMany($0) }
        .fileImporter(isPresented: $pickingBinary, allowedContentTypes: [.item, .data, .unixExecutable]) { ingest($0, .binary) }
        .fileImporter(isPresented: $pickingJSON, allowedContentTypes: [.json, .item], allowsMultipleSelection: true) { ingestMany($0) }
        .fileImporter(isPresented: $pickingMC, allowedContentTypes: [.item, .text, .json, .plainText], allowsMultipleSelection: true) { ingestMC($0) }
        .alert("Erro", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(store.error ?? "") }
    }

    enum Kind { case plist, binary, json }

    func ingest(_ result: Result<URL, Error>, _ kind: Kind) {
        do { try ingestURL(try result.get(), kind: kind) }
        catch { store.error = error.localizedDescription }
    }

    func ingestMany(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() { try ingestURL(url, kind: nil) }
        } catch { store.error = error.localizedDescription }
    }

    func ingestURL(_ url: URL, kind: Kind?) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        if let kind {
            switch kind {
            case .plist: try store.loadPlist(data, name: url.lastPathComponent)
            case .binary: store.loadFramework(data)
            case .json: try store.loadNameMap(data)
            }
        } else {
            try store.ingestAny(data, name: url.lastPathComponent)
        }
    }

    func ingestMC(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try store.ingestMobileConfig(try Data(contentsOf: url), name: url.lastPathComponent)
            }
        } catch { store.error = error.localizedDescription }
    }

    func share(name: String, data: () throws -> Data) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data().write(to: url)
            FileShare.present(url)
        } catch {
            store.error = error.localizedDescription
        }
    }
}

enum FileShare {
    static func present(_ url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = (scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)?.rootViewController
        else { return }
        var top = root
        while let next = top.presentedViewController { top = next }
        if let pop = av.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 12, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true)
    }
}

struct HomeCell: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    var onPlist: () -> Void
    var onBinary: () -> Void
    var onJSON: () -> Void
    var onMC: () -> Void
    var onShareNames: () -> Void

    var body: some View {
        List {
            Section("Arquivos") {
                Button(action: onPlist) {
                    HomeCell(
                        icon: "doc",
                        title: "Plist",
                        value: store.catalog == nil ? "Toque para abrir" : store.plistName
                    )
                }
                .buttonStyle(.plain)
                Button(action: onBinary) {
                    HomeCell(
                        icon: "gearshape.2",
                        title: "SharedModules",
                        value: store.disassembling ? store.status : (store.stubCount == 0 ? "Toque para enviar o framework" : "\(store.stubCount) getters")
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.disassembling)
                Button { store.fetchWebABProps() } label: {
                    HomeCell(
                        icon: "arrow.down.circle",
                        title: "Fetch ABProps",
                        value: store.fetching ? store.status : (store.fetched ? "\(store.namedCount) nomes — toque de novo" : "Toque para buscar no WhatsApp Web")
                    )
                }
                .buttonStyle(.plain)
                .disabled(store.fetching)
            } footer: {
                if store.busy {
                    ProgressView(value: store.disasmPct, total: 100) {
                        Text(store.status)
                    }
                }
            }

            Section("Editor") {
                Button { store.openPatcher() } label: {
                    HomeCell(
                        icon: "slider.horizontal.3",
                        title: "Abrir Patcher",
                        value: "\(store.namedCount) flags no mapa"
                    )
                }
                .buttonStyle(.plain)
                Button(action: onShareNames) {
                    HomeCell(icon: "square.and.arrow.up", title: "Baixar JSON", value: store.names.isEmpty ? "Nada ainda" : "\(store.namedCount) nomes")
                }
                .buttonStyle(.plain)
                .disabled(store.names.isEmpty)
            }

            Section("MobileConfig") {
                Button(action: onMC) {
                    HomeCell(icon: "folder", title: "Enviar arquivos", value: "params_map e names")
                }
                .buttonStyle(.plain)
                if !store.mcConfigs.isEmpty {
                    Button { store.path.append(.mobileConfig) } label: {
                        HomeCell(icon: "list.bullet.rectangle", title: "Abrir mapping", value: "\(store.mcConfigs.count) configs")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct FlagsView: View {
    @Environment(AppStore.self) private var store
    var onShare: () -> Void
    @State private var status: StatusFilter = .all
    @State private var namesFilter: NamesFilter = .all

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, on, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "Todas"
            case .on: "Ativo"
            case .off: "Inativo"
            }
        }
    }
    enum NamesFilter: String, CaseIterable, Identifiable {
        case all, named, unnamed, inject
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "Todos"
            case .named: "Com nome"
            case .unnamed: "Sem nome"
            case .inject: "Injetar"
            }
        }
    }

    var filtered: [FlagRow] {
        let q = store.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = store.allFlags.filter { row in
            let live = store.liveRoot?.flagValue(store: row.storeKey, code: row.code) ?? row.value
            let on = store.isActive(row)
            if status == .on && !on { return false }
            if status == .off && on { return false }
            let named = store.name(for: row.code)
            switch namesFilter {
            case .all: break
            case .named: if named == nil { return false }
            case .unnamed: if named != nil { return false }
            case .inject: if row.layer != "inject" { return false }
            }
            if let topic = store.topic, !topic.matches(named ?? "", code: row.code) { return false }
            if q.isEmpty { return true }
            return row.code.contains(q)
                || (named?.lowercased().contains(q) ?? false)
                || live.lowercased().contains(q)
        }
        return rows.sorted { a, b in
            let an = store.name(for: a.code) != nil
            let bn = store.name(for: b.code) != nil
            if an != bn { return an && !bn }
            return (Int(a.code) ?? 0) < (Int(b.code) ?? 0)
        }
    }

    var body: some View {
        List {
            Section("Injetar") {
                HStack(spacing: 8) {
                    TextField("1777", text: Bindable(store).customCode)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                        .frame(width: 72)
                    TextField("nome", text: Bindable(store).customName)
                        .textInputAutocapitalization(.never)
                    TextField("1", text: Bindable(store).customValue)
                        .font(.body.monospaced())
                        .frame(width: 44)
                    Button("Add") { Keyboard.hide(); store.addCustom() }
                }
            }

            Section("Flags") {
                ForEach(filtered) { row in
                    FlagLine(row: row)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: Bindable(store).query, placement: .navigationBarDrawer(displayMode: .always), prompt: "nome ou código")
        .onSubmit(of: .search) { Keyboard.hide() }
        .navigationTitle("Patcher")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Status", selection: $status) {
                        ForEach(StatusFilter.allCases) { s in Text(s.label).tag(s) }
                    }
                    Picker("Nomes", selection: $namesFilter) {
                        ForEach(NamesFilter.allCases) { n in
                            Text(n == .inject ? "Injetar \(store.injectCount)" : n.label).tag(n)
                        }
                    }
                    Picker("Tópicos", selection: Binding(
                        get: { store.topic?.rawValue ?? "" },
                        set: { v in store.topic = FlagTopic(rawValue: v) }
                    )) {
                        Text("Todos").tag("")
                        ForEach(FlagTopic.allCases) { t in Text(t.label).tag(t.rawValue) }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                Button("Exportar", systemImage: "square.and.arrow.up", action: onShare)
            }
        }
    }
}

struct FlagLine: View {
    @Environment(AppStore.self) private var store
    let row: FlagRow

    var live: String { store.liveRoot?.flagValue(store: row.storeKey, code: row.code) ?? row.value }
    var orig: String { store.catalog?.original.flagValue(store: row.storeKey, code: row.code) ?? row.value }
    var named: String? { store.name(for: row.code) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(wrapIdent(named ?? "sem nome"))
                .font(.body.weight(named == nil ? .regular : .medium))
                .foregroundStyle(named == nil ? .secondary : .primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(alignment: .center, spacing: 8) {
                Text(row.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(store.kind(for: row.code).label)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                if row.layer == "inject" {
                    Text("fora")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                if live != orig {
                    Text("edit")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                control
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    var control: some View {
        switch store.kind(for: row.code) {
        case .bool:
            Toggle("", isOn: Binding(
                get: { live == "1" || live.lowercased() == "true" },
                set: { on in
                    let next: String
                    if live.lowercased() == "true" || live.lowercased() == "false" { next = on ? "true" : "false" }
                    else { next = on ? "1" : "0" }
                    store.setFlag(storeKey: row.storeKey, code: row.code, value: next)
                }
            ))
            .labelsHidden()
            .tint(.blue)
        case .int, .float, .double, .string:
            TextField(store.kind(for: row.code) == .string ? "texto" : "0", text: Binding(
                get: { live },
                set: { store.setFlag(storeKey: row.storeKey, code: row.code, value: $0) }
            ))
            .keyboardType(store.kind(for: row.code) == .string ? .default : (store.kind(for: row.code) == .int ? .numberPad : .decimalPad))
            .font(.body.monospaced())
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 56, maxWidth: store.kind(for: row.code) == .string ? 140 : 88)
            .submitLabel(.done)
            .onSubmit { Keyboard.hide() }
        }
    }
}

func wrapIdent(_ s: String) -> String {
    s.replacingOccurrences(of: "_", with: "_\u{200B}")
}

struct MCView: View {
    @Environment(AppStore.self) private var store
    var onShareMapping: () -> Void
    var onShareOverrides: () -> Void

    var configs: [MCConfig] {
        let q = store.mcQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let src = store.mcConfigs.filter { !$0.name.isEmpty || $0.params.contains { !$0.name.isEmpty } }
        if q.isEmpty { return src.sorted { $0.configId < $1.configId } }
        return src.filter {
            $0.name.lowercased().contains(q)
                || String($0.configId).contains(q)
                || $0.params.contains { $0.name.lowercased().contains(q) }
        }.sorted { $0.configId < $1.configId }
    }

    var body: some View {
        List {
            ForEach(configs) { cfg in
                Section("\(cfg.configId)  \(cfg.name)") {
                    ForEach(cfg.params.filter { !$0.name.isEmpty }) { p in
                        MCParamLine(param: p)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: Bindable(store).mcQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "config, id, param")
        .navigationTitle("MobileConfig")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("JSON", systemImage: "doc", action: onShareMapping)
                Button("Overrides", systemImage: "square.and.arrow.up", action: onShareOverrides)
                    .disabled(store.mcSelected.isEmpty)
            }
        }
    }
}

struct MCParamLine: View {
    @Environment(AppStore.self) private var store
    let param: MCParam

    var on: Bool { store.mcSelected.contains(param.id) }
    var value: String { store.mcValues[param.id] ?? param.type.defaultValue }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(wrapIdent(param.name))
                    .font(.body)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(param.index) · \(param.type.rawValue)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if on {
                if param.type == .bool {
                    Toggle("", isOn: Binding(
                        get: { value == "true" || value == "1" },
                        set: { store.mcValues[param.id] = $0 ? "true" : "false" }
                    ))
                    .labelsHidden()
                    .tint(.blue)
                } else {
                    TextField("", text: Binding(
                        get: { value },
                        set: { store.mcValues[param.id] = $0 }
                    ))
                    .font(.body.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                }
            }
            Button { store.toggleOverride(param) } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.cyan : Color(uiColor: .tertiaryLabel))
            }
            .buttonStyle(.plain)
        }
    }
}
