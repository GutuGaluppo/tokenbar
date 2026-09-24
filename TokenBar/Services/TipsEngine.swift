import Foundation

/// Uma recomendação de economia gerada a partir do uso real.
struct Tip: Identifiable, Equatable {
    enum Kind { case saving, warning }

    let id: String
    let kind: Kind
    let title: String
    /// Por que a dica apareceu, com os números do seu uso.
    let evidence: String
    /// Economia estimada em US$ por mês (nil para avisos sem economia direta).
    let monthlySavingsUSD: Double?
    let steps: [String]

    var savingsText: String? {
        monthlySavingsUSD.map { "≈ \(TokenFormat.usd($0))/mês" }
    }
}

/// Uma cópia leve de `UsageEvent` para as regras não dependerem do SwiftData.
struct TipInput {
    let externalID: String
    let timestamp: Date
    let model: String
    let tool: String?
    let session: String?
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    let costUSD: Double

    var isClaudeCode: Bool { externalID.hasPrefix("cc:") }
    var isAnthropicAPI: Bool { externalID.hasPrefix("ant:") }
    var context: Int { input + cacheWrite + cacheRead }
}

/// Regras de economia. Cada uma olha os últimos `windowDays` dias, estima quanto teria sido
/// economizado e projeta para 30 dias. Valores são estimativas — servem para priorizar.
struct TipsEngine {
    static let windowDays = 14
    /// Dicas com economia menor que isso não aparecem (ruído).
    static let minimumMonthlySavings = 1.0

    let prices: PriceTable

    private var monthFactor: Double { 30 / Double(Self.windowDays) }

    func tips(for events: [TipInput], budgets: BudgetSettings, monthCostUSD: Double, now: Date = .now) -> [Tip] {
        let candidates: [Tip?] = [
            opus5ToOpus55(events),
            opusShortResponses(events),
            longContext(events),
            heavySessionStart(events),
            apiCaching(events),
            apiBatch(events),
            longOutputs(events),
            monthlyPace(budgets: budgets, monthCostUSD: monthCostUSD, now: now),
        ]
        return candidates.compactMap { $0 }
            .filter { $0.kind == .warning || ($0.monthlySavingsUSD ?? 0) >= Self.minimumMonthlySavings }
            .sorted { ($0.kind == .warning ? 1 : 0, $0.monthlySavingsUSD ?? 0) > ($1.kind == .warning ? 1 : 0, $1.monthlySavingsUSD ?? 0) }
    }

    // MARK: - Helpers

    /// Custo desses tokens se tivessem ido para `model` (mesma proporção de preços da tabela).
    func repriced(_ event: TipInput, to model: String) -> Double? {
        let tokens = TokenCounts(input: event.input, output: event.output, cacheWrite5m: event.cacheWrite, cacheRead: event.cacheRead)
        guard let current = prices.cost(model: event.model, tokens: tokens), current > 0,
              let alternative = prices.cost(model: model, tokens: tokens) else { return nil }
        return event.costUSD * alternative / current
    }

    func outputCost(_ event: TipInput) -> Double {
        guard let price = prices.price(for: event.model) else { return 0 }
        return Double(event.output) * price.output / 1_000_000
    }

    func isOpus5(_ model: String) -> Bool {
        model.hasPrefix("claude-opus-5") && !model.hasPrefix("claude-opus-5-5")
    }

    func isOpus(_ model: String) -> Bool { model.hasPrefix("claude-opus") }

    private func usd(_ value: Double) -> String { TokenFormat.usd(value) }

    // MARK: - Regras

    /// Opus 5.5 é da mesma linha e mais barato que o Opus 5 ($4/$20 vs. $5/$25 por MTok).
    private func opus5ToOpus55(_ events: [TipInput]) -> Tip? {
        let matches = events.filter { isOpus5($0.model) && $0.costUSD > 0 }
        guard !matches.isEmpty else { return nil }
        let spent = matches.reduce(0) { $0 + $1.costUSD }
        let saved = matches.reduce(0) { $0 + ($1.costUSD - (repriced($1, to: "claude-opus-5-5") ?? $1.costUSD)) }
        return Tip(
            id: "opus5-to-opus55",
            kind: .saving,
            title: "Trocar Claude Opus 5 por Opus 5.5",
            evidence: "\(matches.count) respostas no Opus 5 em \(Self.windowDays) dias (\(usd(spent))). O Opus 5.5 é o sucessor na mesma linha e custa 20% menos por token.",
            monthlySavingsUSD: saved * monthFactor,
            steps: [
                "No Claude Code: digite /model e escolha Opus 5.5, ou defina \"model\": \"claude-opus-5-5\" em ~/.claude/settings.json.",
                "Na API: troque o id do modelo para claude-opus-5-5.",
                "O Opus 5.5 tem esforço padrão medium (o Opus 5 usa high): ajuste o effort se sentir diferença de qualidade.",
            ]
        )
    }

    /// Muitas respostas curtas no Opus costumam ser passos simples (ler arquivo, rodar comando)
    /// que um modelo menor faz igual.
    private func opusShortResponses(_ events: [TipInput]) -> Tip? {
        let short = events.filter { isOpus($0.model) && $0.output < 1_000 && $0.costUSD > 0 }
        let opusCount = events.filter { isOpus($0.model) }.count
        guard short.count >= 50, opusCount > 0 else { return nil }
        let spent = short.reduce(0) { $0 + $1.costUSD }
        // Supõe que metade desses passos poderia ir para o Sonnet 5.
        let saved = short.reduce(0) { $0 + ($1.costUSD - (repriced($1, to: "claude-sonnet-5") ?? $1.costUSD)) } * 0.5
        let share = Double(short.count) / Double(opusCount)
        return Tip(
            id: "opus-short-steps",
            kind: .saving,
            title: "Deixar passos simples para o Sonnet",
            evidence: "\(share.formatted(.percent.precision(.fractionLength(0)))) das respostas do Opus têm menos de 1k tokens de saída (\(short.count) respostas, \(usd(spent))). Estimativa supõe que metade poderia rodar no Sonnet 5.",
            monthlySavingsUSD: saved * monthFactor,
            steps: [
                "Use o Opus para planejar e decidir, e o Sonnet para executar: /model sonnet durante tarefas mecânicas.",
                "Configure sub-agentes de exploração com model: sonnet (ou haiku) em .claude/agents/.",
                "Em tarefas rotineiras, reduza o esforço (effort low/medium) antes de trocar de modelo.",
            ]
        )
    }

    /// Conversas longas reenviam o contexto inteiro a cada turno; acima de ~100k tokens isso pesa.
    private func longContext(_ events: [TipInput]) -> Tip? {
        let threshold = 100_000
        let heavy = events.filter { $0.isClaudeCode && $0.context > 2 * threshold && $0.costUSD > 0 }
        guard heavy.count >= 20 else { return nil }
        // Custo da parte do contexto acima do limiar.
        let excess = heavy.reduce(0.0) { total, event in
            let contextCost = max(event.costUSD - outputCost(event), 0)
            return total + contextCost * Double(event.context - threshold) / Double(event.context)
        }
        let sessions = Set(heavy.compactMap(\.session)).count
        return Tip(
            id: "long-context",
            kind: .saving,
            title: "Compactar ou recomeçar conversas longas",
            evidence: "\(heavy.count) respostas em \(sessions) sessões rodaram com mais de 200k tokens de contexto. A parte acima de 100k custou \(usd(excess)) em \(Self.windowDays) dias.",
            monthlySavingsUSD: excess * 0.5 * monthFactor,
            steps: [
                "Use /compact quando terminar uma etapa (ex.: \"/compact mantenha só as decisões e arquivos alterados\").",
                "Use /clear ao mudar de tarefa — cada tarefa numa sessão nova.",
                "Peça trechos de arquivos em vez de arquivos inteiros; evite colar logs longos.",
            ]
        )
    }

    /// Sessões que já começam com muito contexto: CLAUDE.md grande, muitos MCPs, skills e plugins.
    private func heavySessionStart(_ events: [TipInput]) -> Tip? {
        let baseline = 25_000
        let bySession = Dictionary(grouping: events.filter { $0.isClaudeCode && $0.session != nil }, by: { $0.session! })
        var heavySessions = 0
        var totalStart = 0
        var saved = 0.0
        for (_, sessionEvents) in bySession {
            guard let first = sessionEvents.min(by: { $0.timestamp < $1.timestamp }),
                  first.context > 40_000, let price = prices.price(for: first.model) else { continue }
            heavySessions += 1
            totalStart += first.context
            let excess = Double(first.context - baseline)
            // Excesso é escrito no cache (1 h, 2×) uma vez e relido em cada turno da sessão.
            saved += excess * (price.input * prices.cacheWrite1hMultiplier + Double(sessionEvents.count) * price.cacheRead) / 1_000_000
        }
        guard heavySessions >= 5 else { return nil }
        let average = totalStart / heavySessions
        return Tip(
            id: "heavy-session-start",
            kind: .saving,
            title: "Enxugar o contexto inicial das sessões",
            evidence: "\(heavySessions) sessões começaram com \(TokenFormat.compact(average)) tokens em média antes da primeira pergunta — prompt de sistema, CLAUDE.md, ferramentas de MCP, skills e plugins. Estimativa para reduzir a ~25k.",
            monthlySavingsUSD: saved * 0.5 * monthFactor,
            steps: [
                "Rode /context numa sessão nova para ver o que ocupa espaço.",
                "Desative servidores MCP e plugins que o projeto não usa (/mcp e /plugin).",
                "Mantenha o CLAUDE.md curto: regras e comandos, não documentação — link para o resto.",
            ]
        )
    }

    /// API Anthropic com pouca leitura de cache: prompts repetidos pagando entrada cheia.
    private func apiCaching(_ events: [TipInput]) -> Tip? {
        let api = events.filter { $0.isAnthropicAPI }
        let input = api.reduce(0) { $0 + $1.input }
        let cacheRead = api.reduce(0) { $0 + $1.cacheRead }
        guard input > 1_000_000 else { return nil }
        let hitRate = Double(cacheRead) / Double(input + cacheRead)
        guard hitRate < 0.3 else { return nil }
        // Supõe metade da entrada cacheável: paga 1,25× uma vez e 0,1× nas leituras (≈ 65% de economia nela).
        let saved = api.reduce(0.0) { total, event in
            guard let price = prices.price(for: event.model) else { return total }
            return total + Double(event.input) * 0.5 * price.input * 0.65 / 1_000_000
        }
        return Tip(
            id: "api-caching",
            kind: .saving,
            title: "Ativar prompt caching na API",
            evidence: "Só \(hitRate.formatted(.percent.precision(.fractionLength(0)))) da entrada na API Anthropic veio do cache (\(TokenFormat.compact(input)) tokens sem cache em \(Self.windowDays) dias). Estimativa supõe metade da entrada reaproveitável.",
            monthlySavingsUSD: saved * monthFactor,
            steps: [
                "Coloque o conteúdo fixo primeiro (tools → system → mensagens) e o variável no fim.",
                "Adicione cache_control: {type: \"ephemeral\"} ao último bloco fixo.",
                "Nada de data/hora ou IDs no prompt de sistema — qualquer byte diferente invalida o cache.",
                "Confira em usage.cache_read_input_tokens que o cache está sendo lido.",
            ]
        )
    }

    /// Trabalho que pode esperar custa 50% menos na Batch API.
    private func apiBatch(_ events: [TipInput]) -> Tip? {
        let api = events.filter { $0.isAnthropicAPI && $0.tool?.contains("batch") != true }
        let spent = api.reduce(0) { $0 + $1.costUSD }
        guard spent >= 20 else { return nil }
        return Tip(
            id: "api-batch",
            kind: .saving,
            title: "Mandar trabalho sem pressa para a Batch API",
            evidence: "\(usd(spent)) em \(Self.windowDays) dias na API Anthropic sem batch. A Batch API custa 50% menos; estimativa supõe que 25% do volume pode esperar até 24 h.",
            monthlySavingsUSD: spent * 0.25 * 0.5 * monthFactor,
            steps: [
                "Candidatos: classificação em massa, resumos, avaliações, geração de dados.",
                "Envie com POST /v1/messages/batches e busque os resultados quando terminar.",
                "Os resultados chegam fora de ordem: use custom_id para casar cada resposta.",
            ]
        )
    }

    /// Respostas muito longas custam pela saída, a parte mais cara do token.
    private func longOutputs(_ events: [TipInput]) -> Tip? {
        let long = events.filter { $0.output > 8_000 }
        guard long.count >= 10 else { return nil }
        let cost = long.reduce(0) { $0 + outputCost($1) }
        return Tip(
            id: "long-outputs",
            kind: .saving,
            title: "Pedir respostas mais enxutas",
            evidence: "\(long.count) respostas passaram de 8k tokens de saída (\(usd(cost)) só em saída). Estimativa de 30% a menos.",
            monthlySavingsUSD: cost * 0.3 * monthFactor,
            steps: [
                "Peça o formato e o tamanho: \"responda em até 5 tópicos\", \"só o diff\".",
                "Peça edições pontuais em vez de reescrever arquivos inteiros.",
                "Na API, limite max_tokens e reduza o effort em tarefas simples.",
            ]
        )
    }

    /// Ritmo do mês projeta estourar o orçamento mensal.
    private func monthlyPace(budgets: BudgetSettings, monthCostUSD: Double, now: Date) -> Tip? {
        guard budgets.monthlyUSD > 0 else { return nil }
        let calendar = Calendar.current
        guard let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let elapsed = now.timeIntervalSince(month.start) / 86_400
        guard elapsed >= 2 else { return nil }
        let days = month.duration / 86_400
        let projected = monthCostUSD / elapsed * days
        guard projected > budgets.monthlyUSD else { return nil }
        let dailyAllowance = max(budgets.monthlyUSD - monthCostUSD, 0) / max(days - elapsed, 1)
        return Tip(
            id: "monthly-pace",
            kind: .warning,
            title: "No ritmo atual, o orçamento do mês estoura",
            evidence: "Projeção de \(usd(projected)) para um limite de \(usd(budgets.monthlyUSD)) (gasto até agora: \(usd(monthCostUSD))). Para fechar no limite, gaste até \(usd(dailyAllowance)) por dia.",
            monthlySavingsUSD: nil,
            steps: [
                "Aplique primeiro as dicas de economia desta lista, da maior para a menor.",
                "Defina um limite diário em Orçamentos para ser avisado antes.",
            ]
        )
    }
}
