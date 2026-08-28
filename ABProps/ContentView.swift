import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var pickingPlist = false
    @State private var pickingBinary = false
    @State private var pickingJSON = false
    @State private var pickingMC = false
    @State private var sharing = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Group {
                    switch store.screen {
                    case .home: HomeView(
                        onPlist: { pickingPlist = true },
                        onBinary: { pickingBinary = true },
                        onJSON: { pickingJSON = true },
                        onMC: { pickingMC = true }
                    )
                    case .flags: FlagsView(onShare: sharePlist)
                    case .mobileConfig: MCView(onShareMapping: shareMapping, onShareOverrides: shareOverrides)
                    }
                }
                if let toast = store.toast {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.toast)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("ABProps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.screen != .home {
                        Button("Início") { store.screen = .home }
                            .font(.system(size: 13))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.screen == .flags {
                        Button("Guardar") { sharePlist() }
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
            }
        }
        .fileImporter(isPresented: $pickingPlist, allowedContentTypes: [.item, .propertyList, .data]) { ingest($0, .plist) }
        .fileImporter(isPresented: $pickingBinary, allowedContentTypes: [.item, .data, .unixExecutable]) { ingest($0, .binary) }
        .fileImporter(isPresented: $pickingJSON, allowedContentTypes: [.json, .item]) { ingest($0, .json) }
        .fileImporter(isPresented: $pickingMC, allowedContentTypes: [.item, .text, .json, .plainText], allowsMultipleSelection: true) { ingestMC($0) }
        .sheet(isPresented: $sharing) {
            if let exportURL { ShareSheet(url: exportURL) }
        }
        .alert("Erro", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(store.error ?? "") }
    }

    enum Kind { case plist, binary, json }

    func ingest(_ result: Result<URL, Error>, _ kind: Kind) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            switch kind {
            case .plist: try store.loadPlist(data, name: url.lastPathComponent)
            case .binary: store.loadFramework(data)
            case .json: try store.loadNameMap(data)
            }
        } catch {
            store.error = error.localizedDescription
        }
    }

    func ingestMC(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                try store.ingestMobileConfig(data, name: url.lastPathComponent)
            }
        } catch {
            store.error = error.localizedDescription
        }
    }

    func sharePlist() { writeShare(name: store.plistName.isEmpty ? "group.net.whatsapp.WhatsApp.shared.plist" : store.plistName, data: { try store.exportPlist() }) }
    func shareMapping() { writeShare(name: "id_name_mapping.json", data: { try store.exportMapping() }) }
    func shareOverrides() { writeShare(name: "mc_overrides.json", data: { try store.exportOverrides() }) }

    func writeShare(name: String, data: () throws -> Data) {
        do {
            let bytes = try data()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try bytes.write(to: url)
            exportURL = url
            sharing = true
        } catch {
            store.error = error.localizedDescription
        }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    var onPlist: () -> Void
    var onBinary: () -> Void
    var onJSON: () -> Void
    var onMC: () -> Void

    var body: some View {
        List {
            Section {
                ProgressView(value: store.disasmPct, total: 100)
                    .tint(.primary)
                Text(store.status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: { Text("Disassemble") }

            Section("ABProps") {
                Button(action: onPlist) {
                    LabeledContent("Plist") {
                        Text(store.catalog == nil ? "abrir" : store.plistName)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Button(action: onBinary) {
                    LabeledContent("SharedModules") {
                        Text(store.namedCount == 0 ? (store.busy ? "a desmontar…" : "subir") : "\(store.namedCount) nomes")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(store.namedCount > 0 ? Color.primary : .secondary)
                    }
                }
                .disabled(store.busy)
                Button("Mapa JSON de nomes", action: onJSON)
                Button("Entrar nas flags") { store.screen = .flags }
                    .disabled(store.catalog == nil)
                    .font(.system(size: 14, weight: .semibold))
            }

            Section("MobileConfig") {
                Text("params_map.txt + params_names_v4_u*.txt → id_name_mapping.json. Os hex do mapa são IDs e deltas; o tipo (vazio/8/c/10) é bool/int/string/double.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Subir params_map / names JSON", action: onMC)
                LabeledContent("Estado") {
                    Text(store.mcMapLoaded ? "\(store.mcConfigs.count) configs · \(store.mcNamesLoaded) name files" : "nada")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button("Abrir mapping / overrides") { store.screen = .mobileConfig }
                    .disabled(store.mcConfigs.isEmpty)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .listStyle(.insetGrouped)
        .font(.system(size: 14))
    }
}

struct FlagsView: View {
    @Environment(AppStore.self) private var store
    var onShare: () -> Void
    @State private var tab = 0

    var filtered: [FlagRow] {
        let q = store.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.allFlags.filter { row in
            let live = store.liveRoot?.flagValue(store: row.storeKey, code: row.code) ?? row.value
            let on = isOn(live)
            if tab == 0 && !on { return false }
            if tab == 1 && on { return false }
            if q.isEmpty { return true }
            let named = store.name(for: row.code) ?? ""
            return row.code.contains(q) || named.lowercased().contains(q) || live.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Activo").tag(0)
                Text("Inactivo").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("nome ou código", text: Bindable(store).query)
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            List(filtered) { row in
                FlagLine(row: row)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
            .font(.system(size: 13))
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(filtered.count) · \(store.namedCount) nomes · \(store.dirtyCount) editados")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Exportar plist", action: onShare)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    func isOn(_ v: String) -> Bool {
        v == "1" || v.lowercased() == "true"
    }
}

struct FlagLine: View {
    @Environment(AppStore.self) private var store
    let row: FlagRow

    var live: String { store.liveRoot?.flagValue(store: row.storeKey, code: row.code) ?? row.value }
    var orig: String { store.catalog?.original.flagValue(store: row.storeKey, code: row.code) ?? row.value }
    var named: String? { store.name(for: row.code) }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(named ?? "sem nome")
                    .font(.system(size: 13, weight: named == nil ? .regular : .medium))
                    .foregroundStyle(named == nil ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.code).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if row.overlay { Text("ovr").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
                    if live != orig { Text("edit").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange) }
                }
            }
            Spacer(minLength: 8)
            if ["0", "1", "true", "false"].contains(live) {
                Toggle("", isOn: Binding(
                    get: { live == "1" || live == "true" },
                    set: { on in
                        let next: String
                        if live == "true" || live == "false" { next = on ? "true" : "false" }
                        else { next = on ? "1" : "0" }
                        store.setFlag(storeKey: row.storeKey, code: row.code, value: next)
                    }
                ))
                .labelsHidden()
                .scaleEffect(0.8)
            } else {
                TextField("valor", text: Binding(
                    get: { live },
                    set: { store.setFlag(storeKey: row.storeKey, code: row.code, value: $0) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 88)
            }
        }
        .padding(.vertical, 1)
    }
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
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("config, id, param", text: Bindable(store).mcQuery)
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            List {
                ForEach(configs) { cfg in
                    Section("\(cfg.configId)  \(cfg.name)") {
                        ForEach(cfg.params.filter { !$0.name.isEmpty }) { p in
                            MCParamLine(param: p)
                                .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                        }
                    }
                }
            }
            .listStyle(.plain)
            .font(.system(size: 13))
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Text("\(store.mcSelected.count) overrides")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("id_name_mapping.json", action: onShareMapping)
                    .font(.system(size: 12, weight: .semibold))
                Button("mc_overrides.json", action: onShareOverrides)
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(store.mcSelected.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct MCParamLine: View {
    @Environment(AppStore.self) private var store
    let param: MCParam

    var on: Bool { store.mcSelected.contains(param.id) }
    var value: String { store.mcValues[param.id] ?? param.type.defaultValue }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(param.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(param.index) · \(param.type.rawValue) · spec \(String(param.specifier, radix: 16))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if on {
                if param.type == .bool {
                    Toggle("", isOn: Binding(
                        get: { value == "true" || value == "1" },
                        set: { store.mcValues[param.id] = $0 ? "true" : "false" }
                    ))
                    .labelsHidden()
                    .scaleEffect(0.8)
                } else {
                    TextField("", text: Binding(
                        get: { value },
                        set: { store.mcValues[param.id] = $0 }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                }
            }
            Button {
                store.toggleOverride(param)
            } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(on ? Color.primary : Color(uiColor: .tertiaryLabel))
            }
            .buttonStyle(.plain)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
