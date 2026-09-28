import Foundation

/// Uma resposta do Claude Code ou do Codex, cópia leve de `UsageEvent` para o motor não depender do SwiftData.
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
    var isCodex = false

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

/// Estado de uma sessão em andamento (Claude Code ou Codex) e as dicas para ela.
struct LiveSession: Identifiable, Equatable {
    let id: String
    let isCodex: Bool
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
    /// Nome da ferramenta para as mensagens.
    var agent: String { isCodex ? "Codex" : "Claude Code" }

    /// Comandos equivalentes em cada ferramenta.
    var compactCommand: String {
        isCodex ? "/compact" : "/compact mantenha as decisões, os arquivos alterados e os próximos passos"
    }
    var clearCommand: String { isCodex ? "/new" : "/clear" }
    var contextCommand: String { isCodex ? "/status" : "/context" }
}

/// O que vale para todas as sessões: limite do plano e orçamento do dia.
struct LiveContext {
    var planSession: LimitStatus?
    var codexSession: LimitStatus?
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

    func sessions(from events: [LiveInput], activity: [String: SessionActivity] = [:],
                  context: LiveContext, now: Date = .now) -> [LiveSession] {
        Dictionary(grouping: events, by: \.session)
            .compactMap { session(id: $0.key, events: $0.value, activity: activity[$0.key] ?? SessionActivity(),
                                  context: context, now: now) }
            .sorted { lhs, rhs in
                let left = lhs.topSeverity?.rawValue ?? -1, right = rhs.topSeverity?.rawValue ?? -1
                return left != right ? left > right : lhs.lastActivity > rhs.lastActivity
            }
    }

    // MARK: - Estado da sessão

    private func session(id: String, events: [LiveInput], activity: SessionActivity,
                         context: LiveContext, now: Date) -> LiveSession? {
        let main = events.filter { !$0.isSidechain }.sorted { $0.timestamp < $1.timestamp }
        guard let first = main.first, let last = main.last else { return nil }

        let isCodex = last.isCodex
        let ttl = isCodex ? 5 * 60 : cacheTTL(main)
        guard now.timeIntervalSince(last.timestamp) < ttl + Self.idleGrace else { return nil }

        let largest = main.map(\.context).max() ?? 0
        let window = prices.price(for: last.model)?.contextWindow ?? activity.contextWindow
            ?? (largest > Self.defaultContextWindow ? Self.extendedContextWindow : Self.defaultContextWindow)
        let costs = callCosts(context: last.context, model: last.model, ttl: ttl, isCodex: isCodex,
                              recent: main.suffix(Self.recentCalls))

        var session = LiveSession(
            id: id,
            isCodex: isCodex,
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
        session.tips = tips(for: session, main: main, activity: activity, context: context, now: now)
        return session
    }

    /// O Claude Code grava o cache com 5 min ou 1 h; vale o da última escrita.
    private func cacheTTL(_ main: [LiveInput]) -> TimeInterval {
        guard let write = main.last(where: { $0.cacheWrite > 0 }) else { return 5 * 60 }
        return write.cacheWrite1h > 0 ? 3_600 : 5 * 60
    }

    /// Próxima chamada: o contexto lido do cache (quente) ou regravado nele (frio), mais a saída média.
    private func callCosts(context: Int, model: String, ttl: TimeInterval, isCodex: Bool,
                           recent: ArraySlice<LiveInput>) -> (warm: Double, cold: Double)? {
        guard let price = prices.price(for: model), !recent.isEmpty else { return nil }
        let averageOutput = Double(recent.reduce(0) { $0 + $1.output }) / Double(recent.count)
        // A OpenAI não cobra a escrita no cache: sem cache, a entrada sai pelo preço cheio.
        let multiplier = isCodex ? 1 : ttl > 5 * 60 ? prices.cacheWrite1hMultiplier : prices.cacheWrite5mMultiplier
        let output = averageOutput * price.output
        return (
            warm: (Double(context) * price.cacheRead + output) / 1_000_000,
            cold: (Double(context) * price.input * multiplier + output) / 1_000_000
        )
    }

    // MARK: - Regras

    private func tips(for session: LiveSession, main: [LiveInput], activity: SessionActivity,
                      context: LiveContext, now: Date) -> [LiveTip] {
        let candidates: [LiveTip?] = [
            contextSize(session),
            // O cache do Codex não informa quanto dura: sem dica de expiração.
            session.isCodex ? nil : cache(session, now: now),
            planSession(session, context: context),
            dailyBudget(session, context: context),
            heavyStart(session),
            errorLoop(activity, now: now),
            largeResult(activity),
            modelSwitch(main, now: now),
            opusMechanical(main),
            branchChange(session, activity: activity),
            repeatedReads(activity),
            rewrites(activity),
            exploration(activity),
            highEffort(main, activity: activity),
        ]
        return candidates.compactMap { $0 }.sorted { $0.severity > $1.severity }
    }

    /// Conversa longa reenvia tudo a cada chamada; perto do limite, a compactação automática decide sozinha o que fica.
    private func contextSize(_ session: LiveSession) -> LiveTip? {
        let percent = session.contextFraction.formatted(.percent.precision(.fractionLength(0)))
        if session.contextFraction >= Self.nearFullFraction {
            return LiveTip(
                id: "context-full",
                severity: .urgent,
                title: String(localized: "Contexto quase cheio (\(percent))"),
                detail: String(localized: "O \(session.agent) compacta sozinho perto do limite e pode descartar o que importa. Compacte agora, antes que ele decida o que fica."),
                command: session.compactCommand
            )
        }
        guard session.context >= Self.largeContext else { return nil }
        let callCost = session.warmCallCostUSD.map { String(localized: " (≈ \(TokenFormat.usd($0)) por chamada)") } ?? ""
        return LiveTip(
            id: "context-large",
            severity: .attention,
            title: String(localized: "Conversa longa: \(TokenFormat.compact(session.context)) tokens"),
            detail: String(localized: "Cada chamada ao modelo reenvia esse contexto\(callCost). Compacte ao fechar uma etapa ou use \(session.clearCommand) ao mudar de tarefa."),
            command: session.compactCommand
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
        guard let plan = session.isCodex ? context.codexSession : context.planSession, plan.fraction >= 0.8, session.context >= 50_000 else { return nil }
        let percent = plan.fraction.formatted(.percent.precision(.fractionLength(0)))
        let reset = plan.resetsAt.map { String(localized: " Reinicia às \($0.formatted(date: .omitted, time: .shortened)).") } ?? ""
        return LiveTip(
            id: "plan-session",
            severity: plan.fraction >= 0.95 ? .urgent : .attention,
            title: String(localized: "Sessão do plano em \(percent)"),
            detail: String(localized: "Cada chamada reenvia \(TokenFormat.compact(session.context)) tokens: compacte para o que resta render mais.\(reset)"),
            command: session.compactCommand
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
            command: session.compactCommand
        )
    }

    // MARK: - Regras sobre o jeito de trabalhar (sinais de ferramentas)

    /// Várias ferramentas falhando em sequência: cada nova tentativa paga o contexto de novo.
    private func errorLoop(_ activity: SessionActivity, now: Date) -> LiveTip? {
        guard activity.trailingErrors >= 4, let last = activity.lastErrorAt,
              now.timeIntervalSince(last) <= 10 * 60 else { return nil }
        return LiveTip(
            id: "error-loop",
            severity: .attention,
            title: String(localized: "\(activity.trailingErrors) tentativas seguidas falharam"),
            detail: String(localized: "Parece um loop. Interrompa (Esc), explique o que está errado ou volte a um ponto anterior com /rewind."),
            command: "/rewind"
        )
    }

    /// Um resultado de ferramenta enorme fica no contexto e é reenviado em toda chamada.
    private func largeResult(_ activity: SessionActivity) -> LiveTip? {
        guard let result = activity.largestRecentResult, result.tokens >= 15_000 else { return nil }
        return LiveTip(
            id: "large-result",
            severity: .attention,
            title: String(localized: "\(result.tool) trouxe ~\(TokenFormat.compact(result.tokens)) tokens"),
            detail: String(localized: "Tudo isso agora é reenviado em cada chamada. Peça trechos: intervalo de linhas, grep, head/tail, ou limite a saída de comandos."),
            command: nil
        )
    }

    /// Trocar de modelo no meio de uma conversa grande invalida o cache: o contexto inteiro é regravado.
    private func modelSwitch(_ main: [LiveInput], now: Date) -> LiveTip? {
        guard main.count >= 2 else { return nil }
        let last = main[main.count - 1], previous = main[main.count - 2]
        guard last.model != previous.model, previous.context >= 50_000,
              last.cacheRead < last.context / 10, now.timeIntervalSince(last.timestamp) <= 10 * 60 else { return nil }
        let tokens = TokenCounts(cacheWrite5m: last.cacheWrite - last.cacheWrite1h, cacheWrite1h: last.cacheWrite1h)
        let cost = prices.cost(model: last.model, tokens: tokens).map { String(localized: " (≈ \(TokenFormat.usd($0)))") } ?? ""
        return LiveTip(
            id: "model-switch",
            severity: .info,
            title: String(localized: "Troca de modelo regravou o cache"),
            detail: String(localized: "Ao passar para \(last.model), \(TokenFormat.compact(last.cacheWrite)) tokens foram gravados de novo no cache\(cost). Numa conversa longa, compacte antes de trocar."),
            command: nil
        )
    }

    /// Opus em passos curtos e repetitivos: o Sonnet faz igual por uma fração do preço.
    private func opusMechanical(_ main: [LiveInput]) -> LiveTip? {
        let recent = main.suffix(12)
        guard recent.count == 12, let model = recent.last?.model, model.hasPrefix("claude-opus"),
              recent.allSatisfy({ $0.model == model }),
              recent.filter({ $0.output < 1_000 }).count >= 10 else { return nil }
        // As mesmas chamadas repreçadas no Sonnet 5.
        var current = 0.0, sonnet = 0.0
        for call in recent {
            let tokens = TokenCounts(input: call.input, output: call.output, cacheWrite5m: call.cacheWrite - call.cacheWrite1h,
                                     cacheWrite1h: call.cacheWrite1h, cacheRead: call.cacheRead)
            guard let now = prices.cost(model: model, tokens: tokens),
                  let alternative = prices.cost(model: "claude-sonnet-5", tokens: tokens) else { return nil }
            current += now
            sonnet += alternative
        }
        guard current > 0 else { return nil }
        let cheaper = 1 - sonnet / current
        guard cheaper > 0.1 else { return nil }
        return LiveTip(
            id: "opus-mechanical",
            severity: .attention,
            title: String(localized: "Etapa mecânica no Opus"),
            detail: String(localized: "As últimas respostas foram curtas, típicas de ler, rodar e editar. No Sonnet 5 cada chamada sai ≈ \(cheaper.formatted(.percent.precision(.fractionLength(0)))) mais barata; volte ao Opus para decidir."),
            command: "/model sonnet"
        )
    }

    /// Mudou de branch na mesma conversa: se for outra tarefa, o contexto antigo só pesa.
    private func branchChange(_ session: LiveSession, activity: SessionActivity) -> LiveTip? {
        guard let change = activity.branchChange, session.context >= Self.cacheContext else { return nil }
        return LiveTip(
            id: "branch-change",
            severity: .info,
            title: String(localized: "Branch mudou para \(change.to)"),
            detail: String(localized: "A conversa carrega \(TokenFormat.compact(session.context)) tokens de \(change.from). Se for uma tarefa nova, comece com /clear."),
            command: session.clearCommand
        )
    }

    private func repeatedReads(_ activity: SessionActivity) -> LiveTip? {
        guard activity.maxWholeFileReads >= 3 else { return nil }
        return LiveTip(
            id: "repeated-reads",
            severity: .info,
            title: String(localized: "Um arquivo foi lido inteiro \(activity.maxWholeFileReads) vezes"),
            detail: String(localized: "Cada leitura entra de novo no contexto. Peça para aproveitar o que já foi lido ou ler só o trecho que mudou."),
            command: nil
        )
    }

    private func rewrites(_ activity: SessionActivity) -> LiveTip? {
        guard activity.maxRewrites >= 2 else { return nil }
        return LiveTip(
            id: "rewrites",
            severity: .info,
            title: String(localized: "Arquivo reescrito inteiro \(activity.maxRewrites) vezes"),
            detail: String(localized: "A saída é a parte mais cara do token. Peça edições pontuais em vez de reescrever o arquivo todo."),
            command: nil
        )
    }

    private func exploration(_ activity: SessionActivity) -> LiveTip? {
        guard activity.recentExploration >= 20 else { return nil }
        return LiveTip(
            id: "exploration",
            severity: .info,
            title: String(localized: "Muita exploração na conversa principal"),
            detail: String(localized: "\(activity.recentExploration) leituras e buscas em 15 min, todas no contexto. Um subagente de exploração faz isso à parte e devolve só o resumo."),
            command: nil
        )
    }

    /// Effort alto em respostas curtas: raciocínio caro para passos simples.
    private func highEffort(_ main: [LiveInput], activity: SessionActivity) -> LiveTip? {
        let high: Set<String> = ["high", "xhigh", "max"]
        let efforts = activity.recentEfforts
        guard efforts.count >= Self.recentCalls, efforts.allSatisfy(high.contains),
              main.suffix(Self.recentCalls).allSatisfy({ $0.output < 1_500 }) else { return nil }
        return LiveTip(
            id: "high-effort",
            severity: .info,
            title: String(localized: "Effort \(efforts.last ?? "high") em passos simples"),
            detail: String(localized: "As últimas respostas foram curtas. Enquanto a tarefa for rotineira, baixe o effort para medium (em /model)."),
            command: nil
        )
    }

    /// Contexto que já existia antes da primeira pergunta.
    private func heavyStart(_ session: LiveSession) -> LiveTip? {
        guard session.startContext >= Self.heavyStart else { return nil }
        return LiveTip(
            id: "heavy-start",
            severity: .info,
            title: String(localized: "Sessão começou com \(TokenFormat.compact(session.startContext)) tokens"),
            detail: session.isCodex
                ? String(localized: "Antes da primeira pergunta: prompt de sistema, AGENTS.md e ferramentas de MCP. Veja o uso de contexto com /status.")
                : String(localized: "Antes da primeira pergunta: prompt de sistema, CLAUDE.md, ferramentas de MCP, skills e plugins. Veja o que ocupa espaço com /context."),
            command: session.contextCommand
        )
    }
}
