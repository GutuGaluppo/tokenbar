import SwiftUI

/// Seção "Orçamentos": limites de custo e limites estimados do plano do Claude Code, com alertas.
struct BudgetsView: View {
    @Environment(UsageStore.self) private var store
    @AppStorage(BudgetKey.dailyUSD) private var dailyUSD = 0.0
    @AppStorage(BudgetKey.monthlyUSD) private var monthlyUSD = 0.0
    @AppStorage(BudgetKey.fiveHourTokens) private var fiveHourTokens = 0.0
    @AppStorage(BudgetKey.weeklyTokens) private var weeklyTokens = 0.0
    @AppStorage(BudgetKey.alertsEnabled) private var alertsEnabled = false
    @State private var notificationsDenied = false

    var body: some View {
        Form {
            if !store.limits.isEmpty {
                Section("Agora") {
                    LimitsList()
                }
            }

            Section {
                currencyField(String(localized: "Limite diário"), value: $dailyUSD, current: store.today.costUSD)
                currencyField(String(localized: "Limite mensal"), value: $monthlyUSD, current: store.monthCostUSD)
            } header: {
                Text("Custo (equivalente em API)")
            } footer: {
                Text("0 desliga o limite. Pressione Enter para confirmar o valor. Soma todas as fontes: Claude Code, API Anthropic e API OpenAI.")
            }

            Section {
                tokenField(String(localized: "Bloco de 5 h"), value: $fiveHourTokens,
                           current: store.claudeCodeLast5h, peak: store.claudeCodePeak5hLast7d)
                tokenField(String(localized: "Últimos 7 dias"), value: $weeklyTokens,
                           current: store.claudeCodeLast7d, peak: nil)
            } header: {
                Text("Claude Code (estimativa dos limites do plano)")
            } footer: {
                Text("Os limites de Pro/Max não são públicos. Conta entrada + saída + escrita de cache (sem leituras de cache). Para calibrar: quando o Claude avisar que você chegou ao limite, use o valor do bloco atual como referência.")
            }

            Section {
                Toggle("Notificar ao atingir 50%, 80% e 95%", isOn: $alertsEnabled)
                if notificationsDenied {
                    Text("Notificações bloqueadas. Ative em Ajustes do Sistema → Notificações → TokenBar.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Alertas")
            }
        }
        .formStyle(.grouped)
        .onChange(of: alertsEnabled) { _, enabled in
            guard enabled else { return }
            Task { notificationsDenied = !(await AlertNotifier.requestAuthorization()) }
        }
    }

    private func currencyField(_ title: String, value: Binding<Double>, current: Double) -> some View {
        LabeledContent {
            HStack {
                Text("atual \(TokenFormat.usd(current))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // Formato numérico simples: aceita "5" ou "12,50" (moeda exigiria digitar "US$ 5,00").
                Text("US$")
                TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
        } label: {
            Text(title)
        }
    }

    private func tokenField(_ title: String, value: Binding<Double>, current: Int, peak: Int?) -> some View {
        LabeledContent {
            HStack {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("atual \(TokenFormat.compact(current))")
                    if let peak {
                        Text("pico 7d \(TokenFormat.compact(peak))").font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
                TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
            }
        } label: {
            Text(title)
        }
    }
}

/// Barras de progresso dos limites ativos (popover, Overview e Orçamentos).
struct LimitsList: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.limits) { limit in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(limit.title)
                        Spacer()
                        Text(limit.fraction.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(tint(for: limit))
                    }
                    ProgressView(value: min(limit.fraction, 1))
                        .tint(tint(for: limit))
                    Group {
                        HStack {
                            Text(limit.usageText)
                            Spacer()
                            Text(limit.remainingText)
                        }
                        if let reset = limit.resetText {
                            Text(reset)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }

    /// Limites de modelo usam a cor do modelo (a sessão um pouco mais clara que a semana);
    /// só o alerta de 95% vira vermelho, para não confundir com o laranja do Claude.
    private func tint(for limit: LimitStatus) -> Color {
        if limit.fraction >= 0.95 { return .red }
        guard let brand = limit.brand else {
            return limit.fraction >= 0.8 ? .orange : .accentColor
        }
        return limit.isSession ? brand.tint.opacity(0.7) : brand.tint
    }
}
