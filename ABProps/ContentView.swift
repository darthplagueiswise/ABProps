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
                                onMC: { pickingMC = true },
                                onShareNames: shareNames
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
            .preferredColorScheme(.dark)
            .searchable(text: Bindable(store).query, placement: .toolbar, prompt: "nome ou código")
            .searchToolbarBehavior(.minimize)
            .onSubmit(of: .search) { Keyboard.hide() }
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
                        Button("Salvar") { sharePlist() }
                            .buttonStyle(.glassProminent)
                    }
                }
                if store.screen == .flags || store.screen == .mobileConfig {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $pickingPlist, allowedContentTypes: [.item, .propertyList, .data, .json, .text], allowsMultipleSelection: true) { ingestMany($0) }
        .fileImporter(isPresented: $pickingBinary, allowedContentTypes: [.item, .data, .unixExecutable]) { ingest($0, .binary) }
        .fileImporter(isPresented: $pickingJSON, allowedContentTypes: [.json, .item], allowsMultipleSelection: true) { ingestMany($0) }
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
            try ingestURL(url, kind: kind)
        } catch {
            store.error = error.localizedDescription
        }
    }

    func ingestMany(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                try ingestURL(url, kind: nil)
            }
        } catch {
            store.error = error.localizedDescription
        }
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
        } catch {
            store.error = error.localizedDescription
        }
    }

    func sharePlist() {
        writeShare(name: store.plistName.isEmpty ? "group.net.whatsapp.WhatsApp.shared.plist" : store.plistName) { try store.exportPlist() }
    }
    func shareMapping() { writeShare(name: "id_name_mapping.json") { try store.exportMapping() } }
    func shareOverrides() { writeShare(name: "mc_overrides.json") { try store.exportOverrides() } }
    func shareNames() { writeShare(name: "abprops-web.json") { try store.exportNames() } }

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
                ? [Color(red: 0.02, green: 0.02, blue: 0.025), Color(red: 0.04, green: 0.045, blue: 0.055), Color(red: 0.0, green: 0.0, blue: 0.0)]
                : [Color(red: 0.12, green: 0.13, blue: 0.15), Color(red: 0.08, green: 0.09, blue: 0.10), Color(red: 0.05, green: 0.05, blue: 0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            Circle()
                .fill(Color.cyan.opacity(dark ? 0.06 : 0.05))
                .frame(width: 240, height: 240)
                .blur(radius: 80)
                .offset(x: -110, y: -220)
            Circle()
                .fill(Color.white.opacity(dark ? 0.03 : 0.04))
                .frame(width: 280, height: 280)
                .blur(radius: 90)
                .offset(x: 140, y: 300)
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
    var onShareNames: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Plist e framework. Os dois.")
                    .font(.title.weight(.semibold))
                    .padding(.top, 8)
                Text("O plist só tem IDs. Os nomes vêm do Cobalt (WAWebABPropsConfigs, 1708) + getters iOS. Esta IPA já traz 2167 nomes — dá pra somar mais JSON em cima.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("Entrar no patcher") { store.openPatcher() }
                    .buttonStyle(.glassProminent)
                    .frame(maxWidth: .infinity)

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
                                Button(store.busy ? "Desmontando…" : "Enviar framework", action: onBinary)
                                    .buttonStyle(.glassProminent)
                                    .disabled(store.busy)
                            }
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Fetch Web").font(.headline)
                        Text("Abre o WhatsApp Web num WebView desktop (igual o Cobalt faz com browser) e lê WAWebABPropsConfigs no JS. Sem fallback — é o fetch real.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(store.busy ? "Buscando…" : "Fetch ABProps") {
                                store.fetchWebABProps()
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(store.busy)
                            Button("Baixar JSON", action: onShareNames)
                                .buttonStyle(.glass)
                                .disabled(store.names.isEmpty)
                        }
                        Button("Entrar no patcher") { store.openPatcher() }
                            .buttonStyle(.glassProminent)
                            .frame(maxWidth: .infinity)
                            .disabled(store.names.isEmpty && store.catalog == nil)
                    }
                }

                Button("Plist + JSON (vários)", action: onPlist)
                    .buttonStyle(.glass)
                Button("Ou mapa JSON de nomes", action: onJSON)
                    .buttonStyle(.glass)

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Custom").font(.headline)
                        Text("Ex. 1777 = is_meta_employee_or_internal_tester (Cobalt).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("código", text: Bindable(store).customCode)
                                .keyboardType(.numberPad)
                                .font(.subheadline.monospaced())
                                .padding(8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                            TextField("nome opcional", text: Bindable(store).customName)
                                .textInputAutocapitalization(.never)
                                .font(.subheadline)
                                .padding(8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                            TextField("valor", text: Bindable(store).customValue)
                                .font(.subheadline.monospaced())
                                .frame(width: 52)
                                .padding(8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                        }
                        Button("Injetar custom") {
                            store.addCustom()
                            store.openPatcher()
                        }
                        .buttonStyle(.glassProminent)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("MobileConfig").font(.headline)
                        Text("params_map.txt + params_names_v4_u*.txt → id_name_mapping.json. Hex = IDs; tipo vazio/8/c/10 = bool/int/string/double.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(store.mcMapLoaded ? "\(store.mcConfigs.count) configs · \(store.mcNamesLoaded) arquivos de nome" : "nada ainda")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Enviar arquivos", action: onMC).buttonStyle(.glassProminent)
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
            if let topic = store.topic, !topic.matches(named ?? "", code: row.code) { return false }
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
                    Text("Ativo").tag(0)
                    Text("Inativo").tag(1)
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
                                Button("Injetar \(store.injectCount)") { store.onlyInject = false }
                                    .buttonStyle(.glassProminent)
                            } else {
                                Button("Injetar \(store.injectCount)") {
                                    store.onlyInject = true
                                    store.onlyUnnamed = false
                                    store.onlyNamed = true
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                }

                GlassEffectContainer {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(FlagTopic.allCases) { t in
                                if store.topic == t {
                                    Button(t.label) { store.topic = nil }
                                        .buttonStyle(.glassProminent)
                                } else {
                                    Button(t.label) { store.topic = t }
                                        .buttonStyle(.glass)
                                }
                            }
                        }
                    }
                }

                CustomInjectBar()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            List(filtered) { row in
                FlagLine(row: row)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                    .listRowSeparator(.visible)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)

            HStack(alignment: .center, spacing: 10) {
                Text("\(filtered.count) · \(store.namedInPlist) no plist · \(store.injectCount) fora · \(store.dirtyCount) editados")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button("Exportar", action: onShare)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(wrapIdent(named ?? "sem nome"))
                .font(.system(size: 13, weight: named == nil ? .regular : .semibold, design: .default))
                .foregroundStyle(named == nil ? .secondary : .primary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(alignment: .center, spacing: 8) {
                Text(row.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(store.kind(for: row.code).label)
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                if row.overlay {
                    Text("ovr")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                }
                if row.layer == "inject" {
                    Text("fora")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                }
                if live != orig {
                    Text("edit")
                        .font(.caption2.weight(.semibold))
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
            .tint(Color.cyan)
            .fixedSize()
        case .int, .float, .double, .string:
            TextField(store.kind(for: row.code) == .string ? "texto" : "0", text: Binding(
                get: { live },
                set: { store.setFlag(storeKey: row.storeKey, code: row.code, value: $0) }
            ))
            .keyboardType(store.kind(for: row.code) == .string ? .default : (store.kind(for: row.code) == .int ? .numberPad : .decimalPad))
            .font(.caption.monospaced())
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 56, maxWidth: store.kind(for: row.code) == .string ? 140 : 88)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
            .submitLabel(.done)
            .onSubmit { Keyboard.hide() }
        }
    }
}

func wrapIdent(_ s: String) -> String {
    s.replacingOccurrences(of: "_", with: "_\u{200B}")
}

struct CustomInjectBar: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        HStack(spacing: 8) {
            TextField("1777", text: Bindable(store).customCode)
                .keyboardType(.numberPad)
                .font(.caption.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .frame(width: 72)
                .submitLabel(.done)
                .onSubmit { Keyboard.hide(); store.addCustom() }
            TextField("nome", text: Bindable(store).customName)
                .textInputAutocapitalization(.never)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            TextField("1", text: Bindable(store).customValue)
                .font(.caption.monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
                .frame(width: 44)
            Button("Add") { Keyboard.hide(); store.addCustom() }
                .buttonStyle(.glassProminent)
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
            .scrollDismissesKeyboard(.immediately)
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
                Text(wrapIdent(param.name))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
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
