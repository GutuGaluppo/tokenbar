import SwiftUI

/// Linha compacta de status de uma API remota (popover).
struct RemoteSourceStatusRow: View {
    @Environment(RemoteSourcesManager.self) private var manager
    let kind: RemoteProviderKind

    var body: some View {
        let state = manager.state(kind)
        HStack(spacing: 8) {
            Circle()
                .fill(color(state.phase))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName)
                Text(detail(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if state.phase == .syncing {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
    }

    private func color(_ phase: RemoteSourcesManager.Phase) -> Color {
        switch phase {
        case .notConfigured: .gray
        case .syncing: .blue
        case .ok: .green
        case .failed: .red
        }
    }

    private func detail(_ state: RemoteSourcesManager.SourceState) -> String {
        switch state.phase {
        case .notConfigured: return String(localized: "Não conectada")
        case .syncing: return String(localized: "Sincronizando…")
        case .failed(let message): return String(localized: "Erro: \(message)")
        case .ok:
            let items = String(localized: "\(state.eventCount.formatted()) registros")
            guard let lastSync = state.lastSync else { return items }
            return items + " · " + lastSync.formatted(.relative(presentation: .named))
        }
    }
}

/// Configuração de uma API remota em Ajustes: status, campo da chave, conectar/desconectar.
struct RemoteSourceSettings: View {
    @Environment(RemoteSourcesManager.self) private var manager
    let kind: RemoteProviderKind
    @State private var key = ""
    @State private var connecting = false

    var body: some View {
        let state = manager.state(kind)
        VStack(alignment: .leading, spacing: 8) {
            RemoteSourceStatusRow(kind: kind)
            if state.hasKey {
                HStack {
                    Button(isFailed(state) ? String(localized: "Tentar de novo") : String(localized: "Sincronizar agora")) {
                        Task { await manager.sync(kind) }
                    }
                    Button("Desconectar", role: .destructive) { manager.disconnect(kind) }
                }
                .disabled(state.phase == .syncing)
            } else {
                HStack {
                    SecureField(kind.keyPlaceholder, text: $key)
                        .textFieldStyle(.roundedBorder)
                    Button("Conectar") {
                        connecting = true
                        Task {
                            if await manager.connect(kind, apiKey: key) { key = "" }
                            connecting = false
                        }
                    }
                    .disabled(key.isEmpty || connecting)
                }
                Text(kind.keyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func isFailed(_ state: RemoteSourcesManager.SourceState) -> Bool {
        if case .failed = state.phase { return true }
        return false
    }
}

/// APIs de qualquer provedor no formato da OpenAI (Kimi, DeepSeek, Groq…): lista das autorizadas e
/// formulário para autorizar a próxima. O consumo é medido pelo proxy local.
struct CustomAPISettings: View {
    @Environment(CustomAPIStore.self) private var store
    @Environment(LocalProxyManager.self) private var proxy

    @State private var preset = CustomAPIPreset.all[0]
    @State private var name = CustomAPIPreset.all[0].name
    @State private var baseURL = CustomAPIPreset.all[0].baseURL ?? ""
    @State private var key = ""
    @State private var inputPrice = ""
    @State private var outputPrice = ""
    @State private var cachedPrice = ""
    @State private var authorizing = false
    @State private var error: String?
    @State private var added: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Outras APIs (via proxy)")
                .font(.headline)

            ForEach(store.apis) { api in
                CustomAPIRow(api: api)
                Divider()
            }
            if !store.apis.isEmpty {
                usageHint
            }
            form
        }
        .padding(.vertical, 4)
    }

    /// Como apontar o app do usuário para o proxy.
    private var usageHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !proxy.isEnabled {
                Label("Ligue o proxy local (acima) para medir o consumo destas APIs.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("No seu app ou SDK, use o endereço do proxy da API como base URL e, como API key, o token local abaixo — o proxy troca pela chave guardada. Se preferir, use a própria chave do provedor: ela passa direto.")
                .foregroundStyle(.secondary)
            HStack {
                Text(verbatim: masked(store.localToken))
                    .font(.callout.monospaced())
                CopyButton(text: store.localToken, label: "Copiar token local")
            }
        }
        .font(.caption)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provedor", selection: $preset) {
                ForEach(CustomAPIPreset.all) { Text(verbatim: $0.name).tag($0) }
            }
            .onChange(of: preset) { _, newValue in
                name = newValue == .custom ? "" : newValue.name
                baseURL = newValue.baseURL ?? ""
            }
            TextField("Nome", text: $name, prompt: Text("ex.: Kimi"))
            TextField("Endereço base", text: $baseURL, prompt: Text(verbatim: "https://api.exemplo.com/v1"))
            SecureField("API key", text: $key, prompt: Text("Chave da API"))
            DisclosureGroup("Preço por milhão de tokens (opcional)") {
                HStack {
                    priceField("Entrada", text: $inputPrice)
                    priceField("Saída", text: $outputPrice)
                    priceField("Cache", text: $cachedPrice)
                }
                Text("Sem preço, o custo vem da tabela de preços quando o modelo está nela; senão fica em US$ 0 e só os tokens são contados.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(authorizing ? String(localized: "Autorizando…") : String(localized: "Autorizar")) { authorize() }
                    .disabled(authorizing || key.isEmpty || baseURL.isEmpty)
                if authorizing { ProgressView().controlSize(.small) }
                if let added {
                    Label("\(added) adicionada", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                }
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Text("A chave é validada listando os modelos (GET /models) e fica no Keychain. Funciona com qualquer API no formato da OpenAI.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func priceField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        TextField(title, text: text, prompt: Text(verbatim: "0,00"))
            .multilineTextAlignment(.trailing)
    }

    private func authorize() {
        authorizing = true
        error = nil
        added = nil
        let pricing = Self.pricing(input: inputPrice, output: outputPrice, cached: cachedPrice)
        let hint = preset == .custom ? nil : preset.id
        Task {
            do {
                let api = try await store.add(name: name, baseURL: baseURL, apiKey: key, pricing: pricing, slugHint: hint)
                added = api.name
                reset()
            } catch {
                self.error = error.localizedDescription
            }
            authorizing = false
        }
    }

    /// Deixa o formulário pronto para a próxima API.
    private func reset() {
        key = ""
        inputPrice = ""
        outputPrice = ""
        cachedPrice = ""
        preset = CustomAPIPreset.all[0]
        name = preset.name
        baseURL = preset.baseURL ?? ""
    }

    /// Entrada e saída são obrigatórias para haver preço; aceita vírgula ou ponto.
    static func pricing(input: String, output: String, cached: String) -> CustomPricing? {
        func number(_ text: String) -> Double? {
            Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        }
        guard let input = number(input), let output = number(output) else { return nil }
        return CustomPricing(input: input, output: output, cachedInput: number(cached))
    }

    private func masked(_ token: String) -> String {
        token.count > 16 ? token.prefix(12) + "…" + token.suffix(4) : token
    }
}

/// Uma API personalizada autorizada: endereço no proxy, modelos e remoção.
struct CustomAPIRow: View {
    @Environment(CustomAPIStore.self) private var store
    @Environment(LocalProxyManager.self) private var proxy
    let api: CustomAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text(api.name).font(.callout.weight(.semibold))
                Text(verbatim: api.baseURL.host() ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remover", role: .destructive) { store.remove(api) }
            }
            HStack {
                Text(verbatim: proxyAddress)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                CopyButton(text: proxyAddress, label: "Copiar endereço")
            }
            if let pricing = api.pricing {
                Text("Entrada \(TokenFormat.usd(pricing.input)) · saída \(TokenFormat.usd(pricing.output)) por milhão de tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !api.models.isEmpty {
                DisclosureGroup("\(api.models.count) modelos") {
                    Text(verbatim: api.models.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private var proxyAddress: String { "http://127.0.0.1:\(proxy.port)/\(api.slug)" }
}

/// Botão pequeno de copiar, com confirmação.
struct CopyButton: View {
    let text: String
    let label: LocalizedStringKey
    @State private var copied = false

    var body: some View {
        Button(label, systemImage: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(label)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
