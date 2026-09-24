import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(LoginItemManager.self) private var loginItem
    @Environment(LocalSources.self) private var localSources
    @Environment(UsageStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(ClaudePlanUsage.self) private var planUsage
    @Environment(PriceUpdater.self) private var priceUpdater
    @Environment(\.openWindow) private var openWindow

    private var priceSourceText: String {
        switch priceUpdater.source {
        case .user: "Personalizada (prices.json), de \(priceUpdater.asOf)"
        case .remote: "Atualizada do repositório, de \(priceUpdater.asOf)"
        case .bundled: "Embutida no app, de \(priceUpdater.asOf)"
        }
    }
    @Environment(\.modelContext) private var modelContext
    @AppStorage(PreferenceKey.menuBarDisplay) private var menuBarDisplay: MenuBarDisplay = .tokensToday
    @AppStorage(PreferenceKey.showDockIconWhenWindowOpen) private var showDockIcon = false
    @AppStorage(GlobalHotKey.enabledKey) private var hotKeyEnabled = false
    @State private var exportRange: CSVExporter.Range = .last30
    @State private var exportMessage: String?

    var body: some View {
        Form {
            Section("Geral") {
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.requiresApproval {
                    LabeledContent("Aguardando aprovação em Ajustes do Sistema") {
                        Button("Abrir") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Picker("Mostrar na barra de menus", selection: $menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                if menuBarDisplay.usesPlan && !planUsage.isEnabled {
                    LabeledContent("Ative a leitura do plano Claude abaixo.") {
                        Button("Ativar") { planUsage.setEnabled(true) }
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
                if menuBarDisplay.usesLimit && store.limits.isEmpty {
                    LabeledContent("Nenhum limite definido: a barra mostra \"—%\".") {
                        Button("Definir limites") { navigation.section = .budgets }
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                }

                Toggle("Mostrar ícone no Dock com a janela aberta", isOn: $showDockIcon)
                Toggle("Atalho global \(GlobalHotKey.displayName) abre o painel", isOn: $hotKeyEnabled)
                LabeledContent("Primeiro uso") {
                    Button("Mostrar boas-vindas") { openWindow(id: Onboarding.windowID) }
                }
            }

            Section {
                Toggle("Ler o uso do plano pela conta do Claude Code", isOn: Binding(
                    get: { planUsage.isEnabled },
                    set: { planUsage.setEnabled($0) }
                ))
                if planUsage.isEnabled {
                    PlanUsageStatusRow()
                    Button("Atualizar agora") { planUsage.refresh(force: true) }
                }
            } header: {
                Text("Plano Claude (Pro/Max)")
            } footer: {
                Text("Mostra os mesmos números de Settings → Usage e do /usage do Claude Code: sessão atual (5 h) e limites semanais. Usa o login do Claude Code guardado no Keychain — o macOS vai pedir permissão; escolha \"Sempre permitir\". O token só é lido e enviado à Anthropic. Endpoint não documentado: pode parar de funcionar sem aviso.")
            }

            Section("Ferramentas locais") {
                ForEach(localSources.all) { source in
                    LocalSourceSettings(source: source)
                }
            }

            Section {
                ForEach(RemoteProviderKind.allCases) { kind in
                    RemoteSourceSettings(kind: kind)
                }
            } header: {
                Text("APIs de uso da organização")
            } footer: {
                Text("As chaves ficam no Keychain e só são usadas para ler relatórios de uso (a cada 5 min). Se o Claude Code usa uma chave de API da mesma organização, esse consumo aparece nos logs e na API Anthropic — conecte só uma das fontes para não contar em dobro.")
            }

            Section("Preços") {
                LabeledContent("Tabela em uso") {
                    Text(priceSourceText).foregroundStyle(.secondary)
                }
                LabeledContent("Atualização") {
                    HStack {
                        if let lastCheck = priceUpdater.lastCheck {
                            Text("verificada " + lastCheck.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary)
                        }
                        Button(priceUpdater.isChecking ? "Verificando…" : "Verificar agora") {
                            Task { await priceUpdater.check() }
                        }
                        .disabled(priceUpdater.isChecking)
                    }
                }
                if let error = priceUpdater.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Personalizar") {
                    Button("Mostrar pasta") {
                        NSWorkspace.shared.activateFileViewerSelecting([Persistence.directory])
                    }
                }
                Text("O app baixa a tabela publicada no repositório uma vez por dia e recalcula os custos quando ela muda. Um prices.json seu nessa pasta sempre prevalece (depois, use Reimportar histórico).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dados") {
                LabeledContent("Banco local") {
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Persistence.storeURL])
                    }
                }
                LabeledContent("Exportar CSV") {
                    HStack {
                        Picker("Período", selection: $exportRange) {
                            ForEach(CSVExporter.Range.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Exportar…") {
                            do {
                                if let count = try CSVExporter.export(range: exportRange, container: modelContext.container) {
                                    exportMessage = "\(count.formatted()) linhas exportadas."
                                }
                            } catch {
                                exportMessage = "Erro: \(error.localizedDescription)"
                            }
                        }
                    }
                }
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            #if DEBUG
            Section("Desenvolvimento") {
                HStack {
                    Button("Gerar dados de exemplo") { SampleData.insert(into: modelContext) }
                    Button("Apagar dados de exemplo", role: .destructive) { SampleData.deleteAll(in: modelContext) }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}

/// Status da leitura do plano Claude (Ajustes).
struct PlanUsageStatusRow: View {
    @Environment(ClaudePlanUsage.self) private var planUsage

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var color: Color {
        switch planUsage.phase {
        case .ok: .green
        case .loading: .blue
        case .disabled: .gray
        case .needsLogin, .failed: .orange
        }
    }

    private var detail: String {
        switch planUsage.phase {
        case .disabled: return "Desligado"
        case .loading: return "Carregando…"
        case .needsLogin(let message): return message
        case .failed(let message): return "Erro: \(message)"
        case .ok:
            let session = planUsage.session.map { "sessão \(Int($0.utilization.rounded()))%" } ?? "sessão —"
            let week = planUsage.week.map { "semana \(Int($0.utilization.rounded()))%" } ?? "semana —"
            let updated = planUsage.lastUpdate.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
            return "\(session) · \(week)\(updated)"
        }
    }
}

/// Uma fonte de logs locais em Ajustes: status, pasta lida e ações.
struct LocalSourceSettings: View {
    let source: LocalLogSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalSourceStatusRow(source: source)
            if !source.roots.isEmpty {
                Text(source.roots.map { $0.path().replacingOccurrences(of: NSHomeDirectory(), with: "~") }
                    .joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if source.eventsWithoutPrice > 0 {
                    Text("\(source.eventsWithoutPrice) respostas de modelos sem preço na tabela (custo contado como US$ 0).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Atualizar agora") { source.scan() }
                    Button("Reimportar histórico") { source.reimport() }
                }
                .disabled(source.isScanning)
            }
        }
        .padding(.vertical, 2)
    }
}
