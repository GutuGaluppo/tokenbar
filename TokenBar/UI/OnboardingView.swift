import SwiftUI
import SwiftData

/// Decide se a tela de primeiro uso aparece.
enum Onboarding {
    static let windowID = "onboarding"
    static let completedKey = "onboarding.completed"

    /// Instalação nova: nunca concluiu e o banco está vazio. Quem já tem dados é marcado como
    /// configurado sem ver a tela. `-onboarding.force YES` força a exibição (desenvolvimento).
    @MainActor
    static func shouldPresent(container: ModelContainer) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "onboarding.force") { return true }
        #endif
        guard !AppEnvironment.isIsolated else { return false }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completedKey) else { return false }
        let existing = (try? container.mainContext.fetchCount(FetchDescriptor<UsageEvent>())) ?? 0
        if existing > 0 {
            defaults.set(true, forKey: completedKey)
            return false
        }
        return true
    }
}

/// Tela de boas-vindas em quatro passos.
struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome, sources, preferences, limits
    }

    @Environment(LocalSources.self) private var localSources
    @Environment(ClaudePlanUsage.self) private var planUsage
    @Environment(LoginItemManager.self) private var loginItem
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(PreferenceKey.menuBarDisplay) private var menuBarDisplay: MenuBarDisplay = .tokensToday
    @AppStorage(BudgetKey.dailyUSD) private var dailyUSD = 0.0
    @AppStorage(BudgetKey.monthlyUSD) private var monthlyUSD = 0.0
    @AppStorage(BudgetKey.alertsEnabled) private var alertsEnabled = false
    @State private var step: Step = {
        #if DEBUG
        // -onboarding.step N abre direto num passo (para conferir a tela em desenvolvimento).
        return Step(rawValue: UserDefaults.standard.integer(forKey: "onboarding.step")) ?? .welcome
        #else
        return .welcome
        #endif
    }()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .sources: sources
                case .preferences: preferences
                case .limits: limits
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            footer
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
        }
        .frame(width: 560, height: 470)
        .onAppear { NSApp.activate() }
    }

    // MARK: - Passos

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Boas-vindas ao TokenBar")
                .font(.largeTitle.weight(.semibold))
            Text("Seu consumo de IA na barra de menus: quanto você usou hoje, quanto resta dos seus limites e onde dá para economizar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                bullet("gauge.with.needle", "Consumo e custo em tempo real, a um clique")
                bullet("chart.bar.xaxis", "Painel por modelo, projeto e horário")
                bullet("lightbulb", "Dicas de economia com o valor estimado")
                bullet("lock", "Tudo fica no seu Mac — nada de conversa é lido")
            }
            .padding(.top, 6)
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Fontes encontradas", "O TokenBar lê os registros que as ferramentas já gravam no seu Mac. Nada precisa ser configurado.")
            ForEach(localSources.all) { source in
                HStack(spacing: 12) {
                    Image(systemName: source.phase == .unavailable ? "xmark.circle" : "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(source.phase == .unavailable ? Color.secondary : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.name).font(.headline)
                        Text(sourceDetail(source))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .scanning(let progress) = source.phase {
                        ProgressView(value: progress).frame(width: 80)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            }
            Text("APIs da Anthropic e da OpenAI (chave de admin da organização) podem ser conectadas depois, em Ajustes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Preferências", "Dá para mudar tudo depois em Ajustes.")
            Form {
                Toggle(isOn: Binding(get: { planUsage.isEnabled }, set: { planUsage.setEnabled($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mostrar os limites do plano Claude (Pro/Max)")
                        Text("Usa o login do Claude Code; o macOS vai pedir acesso ao Keychain. Recurso experimental.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("Na barra de menus", selection: $menuBarDisplay) {
                    ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Abrir ao iniciar sessão", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }

    private var limits: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Limites de custo", "Opcional. Os valores são equivalentes a preços de API; 0 desliga.")
            Form {
                LabeledContent("Limite diário") {
                    HStack {
                        Text("US$")
                        TextField("Diário", value: $dailyUSD, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
                LabeledContent("Limite mensal") {
                    HStack {
                        Text("US$")
                        TextField("Mensal", value: $monthlyUSD, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
                Toggle("Avisar em 50%, 80% e 95%", isOn: $alertsEnabled)
                    .onChange(of: alertsEnabled) { _, enabled in
                        if enabled { Task { _ = await AlertNotifier.requestAuthorization() } }
                    }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
    }

    // MARK: - Rodapé

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Voltar") { move(-1) }
            }
            if step == .limits {
                Button("Começar") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continuar") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Auxiliares

    private func move(_ delta: Int) {
        withAnimation(.snappy) {
            step = Step(rawValue: step.rawValue + delta) ?? step
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Onboarding.completedKey)
        navigation.section = .overview
        openWindow(id: WindowID.dashboard)
        dismissWindow(id: Onboarding.windowID)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .font(.body)
    }

    private func sourceDetail(_ source: LocalLogSource) -> String {
        switch source.phase {
        case .unavailable: "Não encontrado neste Mac"
        case .scanning: "Importando histórico…"
        case .failed(let message): "Erro: \(message)"
        case .idle: "\(source.eventCount.formatted()) respostas importadas"
        }
    }
}
