import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var pickingPlist = false
    @State private var pickingBinary = false
    @State private var pickingJSON = false
    @State private var sharing = false
    @State private var exportURL: URL?
    @State private var selectedBucket: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BackgroundMesh()
                if store.catalog == nil {
                    LandingView(
                        onPlist: { pickingPlist = true },
                        onBinary: { pickingBinary = true },
                        onJSON: { pickingJSON = true }
                    )
                } else {
                    EditorPane(selectedBucket: $selectedBucket)
                }
            }
            .navigationTitle("ABProps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.catalog != nil {
                        Button("Outro") {
                            store.catalog = nil
                            store.liveRoot = nil
                        }
                        .buttonStyle(.glass)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.catalog != nil {
                        Button("Framework") { pickingBinary = true }
                            .buttonStyle(.glass)
                        Button("Guardar") { share() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        }
        .fileImporter(isPresented: $pickingPlist, allowedContentTypes: [.item, .propertyList, .data]) { result in
            ingest(result, kind: .plist)
        }
        .fileImporter(isPresented: $pickingBinary, allowedContentTypes: [.item, .data, .unixExecutable]) { result in
            ingest(result, kind: .binary)
        }
        .fileImporter(isPresented: $pickingJSON, allowedContentTypes: [.json, .item]) { result in
            ingest(result, kind: .json)
        }
        .sheet(isPresented: $sharing) {
            if let exportURL {
                ShareSheet(url: exportURL)
            }
        }
        .alert("Erro", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.error ?? "")
        }
    }

    enum Kind { case plist, binary, json }

    func ingest(_ result: Result<URL, Error>, kind: Kind) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            switch kind {
            case .plist: try store.loadPlist(data, name: url.lastPathComponent)
            case .binary: try store.loadFramework(data)
            case .json: try store.loadNameMap(data)
            }
        } catch {
            store.error = error.localizedDescription
        }
    }

    func share() {
        do {
            let data = try store.exportPlist()
            let name = store.catalog?.fileName ?? "group.net.whatsapp.WhatsApp.shared.plist"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: url)
            exportURL = url
            sharing = true
        } catch {
            store.error = error.localizedDescription
        }
    }
}

struct BackgroundMesh: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.09, blue: 0.14),
                Color(red: 0.12, green: 0.16, blue: 0.22),
                Color(red: 0.05, green: 0.06, blue: 0.08),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        .overlay {
            Circle()
                .fill(Color.cyan.opacity(0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: -80, y: -180)
            Circle()
                .fill(Color.indigo.opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: 120, y: 260)
        }
    }
}

struct LandingView: View {
    var onPlist: () -> Void
    var onBinary: () -> Void
    var onJSON: () -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Código + nome. Liquid Glass no iOS 26.")
                    .font(.largeTitle.weight(.semibold))
                    .padding(.top, 12)
                Text("O disassemble dos getters WAABProperties está nativo (ARM64). Não leva LIEF nem Capstone.")
                    .foregroundStyle(.secondary)
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. Plist").font(.headline)
                        Text("group.net.whatsapp.WhatsApp.shared.plist").font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Button("Abrir plist", action: onPlist)
                            .buttonStyle(.glassProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassEffectContainer {
                    HStack(spacing: 12) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Framework").font(.headline)
                                Text("SharedModules").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Button("Subir", action: onBinary).buttonStyle(.glass)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Mapa JSON").font(.headline)
                                Text("reutilizável").font(.caption).foregroundStyle(.secondary)
                                Button("Subir", action: onJSON).buttonStyle(.glass)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !store.status.isEmpty {
                    Text(store.status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }
}

struct EditorPane: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedBucket: String?

    var body: some View {
        let buckets = store.catalog?.buckets.filter { $0.kind == .flags } ?? []
        let active = buckets.first(where: { $0.id == selectedBucket }) ?? buckets.first
        VStack(spacing: 0) {
            if let catalog = store.catalog {
                Text(catalog.fileName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer {
                    HStack(spacing: 8) {
                        ForEach(buckets) { b in
                            if b.id == active?.id {
                                Button(b.title) { selectedBucket = b.id }
                                    .buttonStyle(.glassProminent)
                            } else {
                                Button(b.title) { selectedBucket = b.id }
                                    .buttonStyle(.glass)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Nome, código ou valor", text: Bindable(store).query)
                    .textInputAutocapitalization(.never)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            HStack {
                Toggle("Com nome", isOn: Bindable(store).onlyNamed).toggleStyle(.switch)
                    .onChange(of: store.onlyNamed) { _, v in if v { store.onlyUnnamed = false } }
                Toggle("Sem nome", isOn: Bindable(store).onlyUnnamed).toggleStyle(.switch)
                    .onChange(of: store.onlyUnnamed) { _, v in if v { store.onlyNamed = false } }
            }
            .font(.footnote)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if let active, let live = store.liveRoot {
                FlagList(bucket: active, live: live)
            }
        }
    }
}

struct FlagList: View {
    @Environment(AppStore.self) private var store
    let bucket: Bucket
    let live: PlistValue

    var rows: [FlagRow] {
        let q = store.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return bucket.flags.filter { row in
            let liveVal = live.flagValue(store: bucket.storeKey, code: row.code) ?? row.value
            let named = store.name(for: row.code)
            if store.onlyNamed && named == nil { return false }
            if store.onlyUnnamed && named != nil { return false }
            if q.isEmpty { return true }
            return row.code.lowercased().contains(q)
                || (named?.lowercased().contains(q) ?? false)
                || liveVal.lowercased().contains(q)
        }
    }

    var body: some View {
        List(rows) { row in
            FlagRowView(bucket: bucket, row: row)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct FlagRowView: View {
    @Environment(AppStore.self) private var store
    let bucket: Bucket
    let row: FlagRow

    var live: String {
        store.liveRoot?.flagValue(store: bucket.storeKey, code: row.code) ?? row.value
    }
    var orig: String {
        store.catalog?.original.flagValue(store: bucket.storeKey, code: row.code) ?? row.value
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.name(for: row.code) ?? "sem nome neste mapa")
                        .font(.body.weight(.medium))
                    if store.name(for: row.code) != nil {
                        Text("iOS")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                    if live != orig {
                        Text("editado")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(row.code + (live != orig ? " · era \(orig)" : ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isToggle(live) {
                Toggle("", isOn: Binding(
                    get: { live == "1" || live == "true" },
                    set: { on in
                        let next: String
                        if live == "true" || live == "false" {
                            next = on ? "true" : "false"
                        } else {
                            next = on ? "1" : "0"
                        }
                        store.setFlag(storeKey: bucket.storeKey, code: row.code, value: next)
                    }
                ))
                .labelsHidden()
            } else {
                TextField("valor", text: Binding(
                    get: { live },
                    set: { store.setFlag(storeKey: bucket.storeKey, code: row.code, value: $0) }
                ))
                .font(.caption.monospaced())
                .frame(maxWidth: 120)
                .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 4)
    }

    func isToggle(_ v: String) -> Bool {
        ["0", "1", "true", "false"].contains(v)
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

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
