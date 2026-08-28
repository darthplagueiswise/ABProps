import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var pickingPlist = false
    @State private var pickingBinary = false
    @State private var pickingJSON = false
    @State private var pickingMC = false
    @State private var sharing = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                BackgroundMesh()
                VStack(spacing: 0) {
                    DisasmBar()
                    Group {
                        switch store.screen {
                        case .home:
                            HomeView(
                                onPlist: { pickingPlist = true },
                                onBinary: { pickingBinary = true },
                                onJSON: { pickingJSON = true },
                                onMC: { pickingMC = true }
                            )
                        case .flags:
                            FlagsView(onShare: sharePlist)
                        case .mobileConfig:
                            MCView(onShareMapping: shareMapping, onShareOverrides: shareOverrides)
                        }
                    }
                }
                if let toast = store.toast {
                    Text(toast)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.bottom, 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: store.toast)
            .navigationTitle("ABProps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.screen != .home {
                        Button {
                            store.screen = .home
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.glass)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if store.screen == .flags {
                        Button("Guardar") { sharePlist() }
                            .buttonStyle(.glassProminent)
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
            for url in try result.get() {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try store.ingestMobileConfig(try Data(contentsOf: url), name: url.lastPathComponent)
            }
        } catch {
            store.error = error.localizedDescription
        }
    }

    func sharePlist() {
        writeShare(name: store.plistName.isEmpty ? "group.net.whatsapp.WhatsApp.shared.plist" : store.plistName) { try store.exportPlist() }
    }
    func shareMapping() { writeShare(name: "id_name_mapping.json") { try store.exportMapping() } }
    func shareOverrides() { writeShare(name: "mc_overrides.json") { try store.exportOverrides() } }

    func writeShare(name: String, data: () throws -> Data) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data().write(to: url)
            exportURL = url
            sharing = true
        } catch {
            store.error = error.localizedDescription
        }
    }
}

struct BackgroundMesh: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        LinearGradient(
            colors: dark
                ? [Color(red: 0.06, green: 0.07, blue: 0.12), Color(red: 0.10, green: 0.13, blue: 0.20), Color(red: 0.04, green: 0.05, blue: 0.07)]
                : [Color(red: 0.90, green: 0.93, blue: 0.98), Color(red: 0.82, green: 0.88, blue: 0.96), Color(red: 0.94, green: 0.95, blue: 0.97)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            Circle()
                .fill(Color.cyan.opacity(dark ? 0.22 : 0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 64)
                .offset(x: -90, y: -200)
            Circle()
                .fill(Color.indigo.opacity(dark ? 0.26 : 0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 72)
                .offset(x: 130, y: 280)
        }
    }
}

struct DisasmBar: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("DISASSEMBLE")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                ProgressView(value: store.disasmPct, total: 100)
                    .tint(.cyan)
                if store.busy { ProgressView().controlSize(.small) }
            }
            Text(store.status)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    var onPlist: () -> Void
    var onBinary: () -> Void
    var onJSON: () -> Void
    var onMC: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Plist e framework. Os dois.")
                    .font(.title.weight(.semibold))
                    .padding(.top, 8)
                Text("O plist tem os códigos. O SharedModules tem os nomes. Capstone (cs_disasm ARM64) corre no aparelho — a barra DISASSEMBLE mostra o progresso.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                GlassEffectContainer {
                    HStack(spacing: 12) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("1 · Plist").font(.headline)
                                Text(store.catalog == nil ? "group.net.whatsapp.WhatsApp.shared.plist" : store.plistName)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Button("Abrir plist", action: onPlist)
                                    .buttonStyle(.glassProminent)
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("2 · SharedModules").font(.headline)
                                Text(store.namedCount == 0 ? "Mach-O · Capstone ARM64" : "\(store.namedCount) nomes · \(store.stubCount) getters")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Button(store.busy ? "A desmontar…" : "Subir framework", action: onBinary)
                                    .buttonStyle(.glassProminent)
                                    .disabled(store.busy)
                            }
                        }
                    }
                }

                if store.catalog != nil {
                    Button("Entrar nas flags") { store.screen = .flags }
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity)
                }

                Button("Ou mapa JSON de nomes", action: onJSON)
                    .buttonStyle(.glass)

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MobileConfig").font(.headline)
                        Text("params_map.txt + params_names_v4_u*.txt → id_name_mapping.json. Hex = IDs; tipo vazio/8/c/10 = bool/int/string/double.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(store.mcMapLoaded ? "\(store.mcConfigs.count) configs · \(store.mcNamesLoaded) name files" : "ainda nada")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Subir ficheiros", action: onMC).buttonStyle(.glassProminent)
                            Button("Abrir mapping") { store.screen = .mobileConfig }
                                .buttonStyle(.glass)
                                .disabled(store.mcConfigs.isEmpty)
                        }
                    }
                }
            }
            .padding(18)
            .padding(.bottom, 40)
        }
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
            let on = live == "1" || live.lowercased() == "true"
            if !store.onlyInject {
                if tab == 0 && !on { return false }
                if tab == 1 && on { return false }
            }
            let named = store.name(for: row.code)
            if store.onlyInject && row.layer != "inject" { return false }
            if store.onlyNamed && named == nil { return false }
            if store.onlyUnnamed && named != nil { return false }
            if q.isEmpty { return true }
            return row.code.contains(q)
                || (named?.lowercased().contains(q) ?? false)
                || live.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text("Activo").tag(0)
                    Text("Inactivo").tag(1)
                }
                .pickerStyle(.segmented)

                GlassEffectContainer {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if store.onlyNamed {
                                Button("Com nome") { store.onlyNamed = false }
                                    .buttonStyle(.glassProminent)
                            } else {
                                Button("Com nome") {
                                    store.onlyNamed = true
                                    store.onlyUnnamed = false
                                }
                                .buttonStyle(.glass)
                            }
                            if store.onlyUnnamed {
                                Button("Sem nome") { store.onlyUnnamed = false }
                                    .buttonStyle(.glassProminent)
                            } else {
                                Button("Sem nome") {
                                    store.onlyUnnamed = true
                                    store.onlyNamed = false
                                    store.onlyInject = false
                                }
                                .buttonStyle(.glass)
                            }
                            if store.onlyInject {
                                Button("Injectar \(store.injectCount)") { store.onlyInject = false }
                                    .buttonStyle(.glassProminent)
                            } else {
                                Button("Injectar \(store.injectCount)") {
                                    store.onlyInject = true
                                    store.onlyUnnamed = false
                                    store.onlyNamed = true
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                    TextField("nome ou código", text: Bindable(store).query)
                        .textInputAutocapitalization(.never)
                        .font(.subheadline)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            List(filtered) { row in
                FlagLine(row: row)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(filtered.count) · \(store.namedInPlist) no plist · \(store.injectCount) injectáveis · \(store.dirtyCount) editados")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Exportar plist", action: onShare)
                    .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 0))
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
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(named ?? "sem nome")
                        .font(.subheadline.weight(named == nil ? .regular : .medium))
                        .foregroundStyle(named == nil ? .secondary : .primary)
                        .lineLimit(1)
                    if named != nil {
                        Text("resolvido")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                    if row.overlay {
                        Text("ovr")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                    if row.layer == "inject" {
                        Text("injectar")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                    if live != orig {
                        Text("edit").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                Text(row.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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
                .tint(.cyan)
            } else {
                TextField("valor", text: Binding(
                    get: { live },
                    set: { store.setFlag(storeKey: row.storeKey, code: row.code, value: $0) }
                ))
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 88)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
            }
        }
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("config, id, param", text: Bindable(store).mcQuery)
                    .textInputAutocapitalization(.never)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            List {
                ForEach(configs) { cfg in
                    Section {
                        ForEach(cfg.params.filter { !$0.name.isEmpty }) { p in
                            MCParamLine(param: p)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("\(cfg.configId)  \(cfg.name)")
                            .font(.caption.monospaced())
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(store.mcSelected.count) overrides")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("mapping", action: onShareMapping).buttonStyle(.glass)
                Button("overrides", action: onShareOverrides)
                    .buttonStyle(.glassProminent)
                    .disabled(store.mcSelected.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 0))
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
            VStack(alignment: .leading, spacing: 2) {
                Text(param.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(param.index) · \(param.type.rawValue)")
                    .font(.caption2.monospaced())
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
                    .tint(.cyan)
                } else {
                    TextField("", text: Binding(
                        get: { value },
                        set: { store.mcValues[param.id] = $0 }
                    ))
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .rect(cornerRadius: 8))
                }
            }
            Button { store.toggleOverride(param) } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(on ? Color.cyan : Color(uiColor: .tertiaryLabel))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
