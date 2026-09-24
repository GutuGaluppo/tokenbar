import Foundation

enum BudgetKey {
    static let dailyUSD = "budget.dailyUSD"
    static let monthlyUSD = "budget.monthlyUSD"
    static let fiveHourTokens = "budget.claudeCode5hTokens"
    static let weeklyTokens = "budget.claudeCodeWeeklyTokens"
    static let alertsEnabled = "budget.alertsEnabled"
}

/// Um limite configurado e quanto dele já foi usado.
struct LimitStatus: Identifiable, Equatable {
    enum Kind: String {
        case dailyCost, monthlyCost, fiveHourTokens, weeklyTokens
        // Limites reais do plano Claude, lidos da Anthropic (utilização em %).
        case planSession, planWeek, planWeekSonnet, planWeekOpus
        // Limites do plano do Codex, lidos dos logs locais.
        case codexSession, codexWeek

        var isPercent: Bool {
            [.planSession, .planWeek, .planWeekSonnet, .planWeekOpus, .codexSession, .codexWeek].contains(self)
        }
    }

    let kind: Kind
    let used: Double
    let limit: Double
    let resetsAt: Date?
    /// Identifica o período atual, para não repetir o mesmo alerta dentro dele.
    let periodID: String

    var id: String { kind.rawValue }
    var fraction: Double { limit > 0 ? used / limit : 0 }
    var remainingFraction: Double { max(1 - fraction, 0) }

    var remainingText: String {
        String(localized: "restam \(remainingFraction.formatted(.percent.precision(.fractionLength(0))))")
    }

    var title: String {
        switch kind {
        case .dailyCost: String(localized: "Custo de hoje")
        case .monthlyCost: String(localized: "Custo do mês")
        case .fiveHourTokens: String(localized: "Claude Code · 5 h")
        case .weeklyTokens: String(localized: "Claude Code · 7 dias")
        case .planSession: String(localized: "Plano · sessão atual")
        case .planWeek: String(localized: "Plano · semana (todos os modelos)")
        case .planWeekSonnet: String(localized: "Plano · semana (Sonnet)")
        case .planWeekOpus: String(localized: "Plano · semana (Opus)")
        case .codexSession: String(localized: "Codex · 5 h")
        case .codexWeek: String(localized: "Codex · semana")
        }
    }

    /// Título curto para o widget.
    var shortTitle: String {
        switch kind {
        case .dailyCost: String(localized: "Custo hoje")
        case .monthlyCost: String(localized: "Custo mês")
        case .fiveHourTokens: String(localized: "Claude Code 5 h")
        case .weeklyTokens: String(localized: "Claude Code 7 d")
        case .planSession: String(localized: "Sessão Claude")
        case .planWeek: String(localized: "Semana Claude")
        case .planWeekSonnet: String(localized: "Semana Sonnet")
        case .planWeekOpus: String(localized: "Semana Opus")
        case .codexSession: String(localized: "Codex 5 h")
        case .codexWeek: String(localized: "Codex semana")
        }
    }

    var usageText: String {
        switch kind {
        case .dailyCost, .monthlyCost:
            String(localized: "\(TokenFormat.usd(used)) de \(TokenFormat.usd(limit))")
        case .fiveHourTokens, .weeklyTokens:
            String(localized: "\(TokenFormat.compact(Int(used))) de \(TokenFormat.compact(Int(limit)))")
        case .planSession, .planWeek, .planWeekSonnet, .planWeekOpus, .codexSession, .codexWeek:
            String(localized: "\((used / 100).formatted(.percent.precision(.fractionLength(0)))) usado")
        }
    }

    var resetText: String? {
        guard let resetsAt else { return nil }
        return String(localized: "reinicia \(resetsAt.formatted(.relative(presentation: .named)))")
    }
}

extension MenuBarDisplay {
    /// Limite que decide o aviso (⚠︎) no ícone: o mesmo que a barra mostra. Com a sessão do plano,
    /// só a sessão; nos demais modos, o limite mais próximo de estourar.
    func warningLimit(in limits: [LimitStatus]) -> LimitStatus? {
        switch self {
        case .planSessionUsed, .planSessionRemaining:
            limits.first { $0.kind == .planSession }
        case .iconOnly, .tokensToday, .costToday, .nearestLimit, .nearestLimitUsed:
            limits.max { $0.fraction < $1.fraction }
        }
    }

    static let warningThreshold = 0.8
}

/// Configuração lida do UserDefaults (0 = limite desligado).
struct BudgetSettings: Equatable {
    var dailyUSD: Double
    var monthlyUSD: Double
    var fiveHourTokens: Double
    var weeklyTokens: Double

    static func load(_ defaults: UserDefaults = .standard) -> BudgetSettings {
        BudgetSettings(
            dailyUSD: defaults.double(forKey: BudgetKey.dailyUSD),
            monthlyUSD: defaults.double(forKey: BudgetKey.monthlyUSD),
            fiveHourTokens: defaults.double(forKey: BudgetKey.fiveHourTokens),
            weeklyTokens: defaults.double(forKey: BudgetKey.weeklyTokens)
        )
    }
}

extension UsageEvent {
    /// Tokens que contam para os limites estimados do Claude Code: tudo menos leituras de cache,
    /// que são baratas e dominariam o total.
    var limitTokens: Int { inputTokens + outputTokens + cacheWriteTokens }

    var isClaudeCode: Bool { externalID.hasPrefix("cc:") }
}
