import Foundation

/// Uma resposta do Claude Code, cópia leve de `UsageEvent` para o motor não depender do SwiftData.
struct LiveInput {
    let timestamp: Date
    let model: String
    let project: String?
    let tool: String?
    let session: String
    let isSidechain: Bool
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheWrite1h: Int
    let cacheRead: Int
    let costUSD: Double

    /// Tokens enviados ao modelo nessa chamada: o tamanho da conversa naquele momento.
    var context: Int { input + cacheWrite + cacheRead }
}

/// Uma dica sobre o que fazer agora numa sessão ativa.
struct LiveTip: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case info, attention, urgent
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Identifica a regra (uma dica por regra e sessão).
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    /// Comando para colar na sessão (ex.: `/compact …`).
    let command: String?
}

/// Estado de uma sessão do Claude Code em andamento e as dicas para ela.
struct LiveSession: Identifiable, Equatable {
    let id: String
    let project: String?
    let tool: String?
    let model: String
    let lastActivity: Date
    /// Chamadas ao modelo na conversa principal (sem subagentes).
    let calls: Int
    /// Custo da sessão inteira, subagentes incluídos.
    let costUSD: Double
    let context: Int
    let startContext: Int
    let contextWindow: Int
    let cacheTTL: TimeInterval
    /// Custo estimado da próxima chamada com o cache quente e depois que ele expirar (nil sem preço).
    let warmCallCostUSD: Double?
    let coldCallCostUSD: Double?
    var tips: [LiveTip]

    var cacheExpiresAt: Date { lastActivity.addingTimeInterval(cacheTTL) }
    var contextFraction: Double { min(Double(context) / Double(contextWindow), 1) }
    var topSeverity: LiveTip.Severity? { tips.map(\.severity).max() }
}

/// O que vale para todas as sessões: limite do plano e orçamento do dia.
struct LiveContext {
    var planSession: LimitStatus?
    var dailyBudgetUSD = 0.0
    var todayCostUSD = 0.0
}

/// Dicas ao vivo: olham cada sessão ativa do Claude Code e dizem o que fazer antes do próximo prompt.
/// Ao contrário do `TipsEngine`, que resume 14 dias, aqui o que importa é o estado de agora.
struct LiveSessionsEngine {
    /// Contexto a partir do qual cada chamada já pesa (dica "conversa longa").
    static let largeContext = 100_000
    /// Fração da janela em que vale compactar antes da compactação automática do Claude Code.
    static let nearFullFraction = 0.8
    /// Contexto mínimo para valer avisar sobre o cache.
    static let cacheContext = 30_000
    /// Sessão que já começa com isso de contexto tem prompt de sistema, MCPs ou CLAUDE.md pesados.
    static let heavyStart = 40_000
    /// Janela padrão dos modelos; quem já passou dela está numa janela estendida.
    static let defaultContextWindow = 200_000
    static let extendedContextWindow = 1_000_000
    /// Depois que o cache expira, a sessão continua na lista por mais esse tempo.
    static let idleGrace: TimeInterval = 30 * 60
    /// Chamadas recentes usadas para estimar a saída da próxima.
    static let recentCalls = 10

    let prices: PriceTable

    func sessions(from events: [LiveInput], context: LiveContext, now: Date = .now) -> [LiveSession] {
        Dictionary(grouping: events, by: \.session)
            .compactMap { session(id: $0.key, events: $0.value, context: context, now: now) }
            .sorted { lhs, rhs in
                let left = lhs.topSeverity?.rawValue ?? -1, right = rhs.topSeverity?.rawValue ?? -1
                return left != right ? left > right : lhs.lastActivity > rhs.lastActivity
            }
    }

    // MARK: - Estado da sessão

    private func session(id: String, events: [LiveInput], context: LiveContext, now: Date) -> LiveSession? {
        let main = events.filter { !$0.isSidechain }.sorted { $0.timestamp < $1.timestamp }
        guard let first = main.first, let last = main.last else { return nil }

        let ttl = cacheTTL(main)
        guard now.timeIntervalSince(last.timestamp) < ttl + Self.idleGrace else { return nil }

        let largest = main.map(\.context).max() ?? 0
        let window = prices.price(for: last.model)?.contextWindow
            ?? (largest > Self.defaultContextWindow ? Self.extendedContextWindow : Self.defaultContextWindow)
        let costs = callCosts(context: last.context, model: last.model, ttl: ttl, recent: main.suffix(Self.recentCalls))

        var session = LiveSession(
            id: id,
            project: last.project,
            tool: last.tool,
            model: last.model,
            lastActivity: last.timestamp,
            calls: main.count,
            costUSD: events.reduce(0) { $0 + $1.costUSD },
            context: last.context,
            startContext: first.context,
            contextWindow: window,
            cacheTTL: ttl,
            warmCallCostUSD: costs?.warm,
            coldCallCostUSD: costs?.cold,
            tips: []
        )
        session.tips = tips(for: session, context: context, now: now)
        return session
    }

    /// O Claude Code grava o cache com 5 min ou 1 h; vale o da última escrita.
    private func cacheTTL(_ main: [LiveInput]) -> TimeInterval {
        guard let write = main.last(where: { $0.cacheWrite > 0 }) else { return 5 * 60 }
        return write.cacheWrite1h > 0 ? 3_600 : 5 * 60
    }

    /// Próxima chamada: o contexto lido do cache (quente) ou regravado nele (frio), mais a saída média.
    private func callCosts(context: Int, model: String, ttl: TimeInterval, recent: ArraySlice<LiveInput>) -> (warm: Double, cold: Double)? {
        guard let price = prices.price(for: model), !recent.isEmpty else { return nil }
        let averageOutput = Double(recent.reduce(0) { $0 + $1.output }) / Double(recent.count)
        let multiplier = ttl > 5 * 60 ? prices.cacheWrite1hMultiplier : prices.cacheWrite5mMultiplier
        let output = averageOutput * price.output
        return (
            warm: (Double(context) * price.cacheRead + output) / 1_000_000,
            cold: (Double(context) * price.input * multiplier + output) / 1_000_000
        )
    }

    // MARK: - Regras

    private func tips(for session: LiveSession, context: LiveContext, now: Date) -> [LiveTip] {
        let candidates: [LiveTip?] = [
            contextSize(session),
            cache(session, now: now),
            planSession(session, context: context),
            dailyBudget(session, context: context),
            heavyStart(session),
        ]
        return candidates.compactMap { $0 }.sorted { $0.severity > $1.severity }
    }

    private static let compactCommand = "/compact mantenha as decisões, os arquivos alterados e os próximos passos"

    /// Conversa longa reenvia tudo a cada chamada; perto do limite, a compactação automática decide sozinha o que fica.
    private func contextSize(_ session: LiveSession) -> LiveTip? {
        let percent = session.contextFraction.formatted(.percent.precision(.fractionLength(0)))
        if session.contextFraction >= Self.nearFullFraction {
            return LiveTip(
                id: "context-full",
                severity: .urgent,
                title: String(localized: "Contexto quase cheio (\(percent))"),
                detail: String(localized: "O Claude Code compacta sozinho perto do limite e pode descartar o que importa. Compacte agora, dizendo o que manter."),
                command: Self.compactCommand
            )
        }
        guard session.context >= Self.largeContext else { return nil }
        let callCost = session.warmCallCostUSD.map { String(localized: " (≈ \(TokenFormat.usd($0)) por chamada)") } ?? ""
        return LiveTip(
            id: "context-large",
            severity: .attention,
            title: String(localized: "Conversa longa: \(TokenFormat.compact(session.context)) tokens"),
            detail: String(localized: "Cada chamada ao modelo reenvia esse contexto\(callCost). Compacte ao fechar uma etapa ou use /clear ao mudar de tarefa."),
            command: Self.compactCommand
        )
    }

    /// Parada longa: o cache expira e a próxima chamada paga para regravar o contexto inteiro.
    private func cache(_ session: LiveSession, now: Date) -> LiveTip? {
        guard session.context >= Self.cacheContext else { return nil }
        let remaining = session.cacheExpiresAt.timeIntervalSince(now)
        let lead: TimeInterval = session.cacheTTL > 5 * 60 ? 10 * 60 : 90
        let cold = session.coldCallCostUSD.map(TokenFormat.usd)
        let warm = session.warmCallCostUSD.map(TokenFormat.usd)

        if remaining > 0, remaining <= lead {
            let time = session.cacheExpiresAt.formatted(date: .omitted, time: .shortened)
            let costs = cold.flatMap { cold in warm.map { String(localized: " (≈ \(cold) em vez de \($0))") } } ?? ""
            return LiveTip(
                id: "cache-expiring",
                severity: .attention,
                title: String(localized: "Cache expira às \(time)"),
                detail: String(localized: "Voltando depois disso, a próxima chamada regrava \(TokenFormat.compact(session.context)) tokens no cache\(costs)."),
                command: nil
            )
        }
        guard remaining <= 0 else { return nil }
        let cost = cold.map { String(localized: " (≈ \($0))") } ?? ""
        return LiveTip(
            id: "cache-expired",
            severity: .info,
            title: String(localized: "Cache expirado"),
            detail: String(localized: "A próxima chamada regrava \(TokenFormat.compact(session.context)) tokens no cache\(cost). Se for mudar de assunto, comece com /clear."),
            command: "/clear"
        )
    }

    /// Sessão do plano Claude apertando: contexto grande gasta o limite mais depressa.
    private func planSession(_ session: LiveSession, context: LiveContext) -> LiveTip? {
        guard let plan = context.planSession, plan.fraction >= 0.8, session.context >= 50_000 else { return nil }
        let percent = plan.fraction.formatted(.percent.precision(.fractionLength(0)))
        let reset = plan.resetsAt.map { String(localized: " Reinicia às \($0.formatted(date: .omitted, time: .shortened)).") } ?? ""
        return LiveTip(
            id: "plan-session",
            severity: plan.fraction >= 0.95 ? .urgent : .attention,
            title: String(localized: "Sessão do plano em \(percent)"),
            detail: String(localized: "Cada chamada reenvia \(TokenFormat.compact(session.context)) tokens: compacte para o que resta render mais.\(reset)"),
            command: Self.compactCommand
        )
    }

    /// Orçamento do dia perto do fim, com esta sessão responsável por boa parte.
    private func dailyBudget(_ session: LiveSession, context: LiveContext) -> LiveTip? {
        guard context.dailyBudgetUSD > 0, context.todayCostUSD >= context.dailyBudgetUSD * 0.8,
              session.costUSD >= context.todayCostUSD * 0.5 else { return nil }
        let share = (session.costUSD / context.dailyBudgetUSD).formatted(.percent.precision(.fractionLength(0)))
        return LiveTip(
            id: "daily-budget",
            severity: .attention,
            title: String(localized: "Esta sessão já gastou \(share) do orçamento do dia"),
            detail: String(localized: "\(TokenFormat.usd(session.costUSD)) de \(TokenFormat.usd(context.dailyBudgetUSD)). Compacte, troque para um modelo menor (/model) ou encerre a tarefa."),
            command: Self.compactCommand
        )
    }

    /// Contexto que já existia antes da primeira pergunta.
    private func heavyStart(_ session: LiveSession) -> LiveTip? {
        guard session.startContext >= Self.heavyStart else { return nil }
        return LiveTip(
            id: "heavy-start",
            severity: .info,
            title: String(localized: "Sessão começou com \(TokenFormat.compact(session.startContext)) tokens"),
            detail: String(localized: "Antes da primeira pergunta: prompt de sistema, CLAUDE.md, ferramentas de MCP, skills e plugins. Veja o que ocupa espaço com /context."),
            command: "/context"
        )
    }
}
