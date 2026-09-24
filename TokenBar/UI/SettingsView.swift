import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(LoginItemManager.self) private var loginItem
    @Environment(LocalSources.self) private var localSources
    @Environment(UsageStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(ClaudePlanUsage.self) private var planUsage
    @Environment(\.modelContext) private var modelContext
    @AppStorage(PreferenceKey.menuBarDisplay) private var menuBarDisplay: MenuBarDisplay = .tokensToday
    @AppStorage(PreferenceKey.showDockIconWhenWindowOpen) private var showDockIcon = false

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
                LabeledContent("Tabela") {
                    Text("Anthropic, \(PriceTable.load().asOf) · OpenAI usa o custo oficial da API").foregroundStyle(.secondary)
                }
                LabeledContent("Personalizar") {
                    Button("Mostrar pasta") {
                        NSWorkspace.shared.activateFileViewerSelecting([Persistence.directory])
                    }
                }
                Text("Para editar preços, salve um prices.json nessa pasta (mesmo formato do arquivo embutido) e clique em Reimportar histórico.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dados") {
                LabeledContent("Banco local") {
                    Button("Mostrar no Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Persistence.storeURL])
                    }
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
