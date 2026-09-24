import Foundation
import Testing
@testable import TokenBar

@Suite("Motor de dicas e economia realizada")
struct TipsTests {
    let engine = TipsEngine(prices: Fixtures.prices)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Resposta do Claude Code com o contexto informado (quase tudo lido do cache).
    private func claudeCode(daysAgo: Double, context: Int, model: String = "claude-sonnet-5",
                            session: String = "s", output: Int = 500) -> TipInput {
        let input = 1_000
        let cacheRead = max(context - input, 0)
        let tokens = TokenCounts(input: input, output: output, cacheRead: cacheRead)
        return TipInput(
            externalID: "cc:\(UUID().uuidString)", timestamp: now.addingTimeInterval(-daysAgo * 86_400),
            model: model, tool: "Claude Code (CLI)", session: session,
            input: input, output: output, cacheWrite: 0, cacheRead: cacheRead,
            costUSD: Fixtures.prices.cost(model: model, tokens: tokens) ?? 0
        )
    }

    @Test("Conversas longas geram a dica com economia estimada")
    func longContextTip() throws {
        let events = (0..<30).map { claudeCode(daysAgo: Double($0) / 3, context: 260_000) }
        let tips = engine.tips(for: events, budgets: BudgetSettings(dailyUSD: 0, monthlyUSD: 0, fiveHourTokens: 0, weeklyTokens: 0),
                               monthCostUSD: 0, now: now)
        let tip = try #require(tips.first { $0.id == "long-context" })
        #expect((tip.monthlySavingsUSD ?? 0) > 0)
    }

    @Test("Opus 5 sugere o Opus 5.5 com a diferença de preço da tabela")
    func opusTip() throws {
        // 100 respostas: acima do mínimo de US$ 1/mês para a dica aparecer.
        let events = (0..<100).map { claudeCode(daysAgo: Double($0) / 8, context: 20_000, model: "claude-opus-5") }
        let tips = engine.tips(for: events, budgets: BudgetSettings(dailyUSD: 0, monthlyUSD: 0, fiveHourTokens: 0, weeklyTokens: 0),
                               monthCostUSD: 0, now: now)
        let tip = try #require(tips.first { $0.id == "opus5-to-opus55" })
        // Mesmos tokens a preços do Opus 5.5 (entrada e saída 20% menores, leitura de cache 60% menor).
        let expected = events.reduce(0.0) { total, event in
            let tokens = TokenCounts(input: event.input, output: event.output, cacheRead: event.cacheRead)
            return total + event.costUSD - (Fixtures.prices.cost(model: "claude-opus-5-5", tokens: tokens) ?? 0)
        }
        let saved = try #require(tip.monthlySavingsUSD) / (30.0 / Double(TipsEngine.windowDays))
        #expect(abs(saved - expected) < 1e-9)
    }

    @Test("Ritmo do mês avisa quando a projeção passa do orçamento")
    func monthlyPaceWarning() {
        let calendar = Calendar.current
        let midMonth = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 12))!
        let budgets = BudgetSettings(dailyUSD: 0, monthlyUSD: 100, fiveHourTokens: 0, weeklyTokens: 0)
        let tips = engine.tips(for: [], budgets: budgets, monthCostUSD: 90, now: midMonth)
        #expect(tips.contains { $0.id == "monthly-pace" && $0.kind == .warning })
    }

    // MARK: - Economia realizada

    private func applied(daysAgo: Double) -> AppliedTip {
        AppliedTip(id: "long-context", title: "Conversas longas", appliedAt: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("Menos de 2 dias depois de aplicar: ainda medindo")
    func measuring() {
        let result = RealizedSaving.evaluate(applied(daysAgo: 1), engine: engine, events: [], now: now)
        guard case .measuring = result.status else {
            Issue.record("esperava .measuring, veio \(result.status)")
            return
        }
    }

    @Test("Desperdício por resposta caiu: economia positiva")
    func savedAfterApplying() throws {
        let before = (0..<40).map { claudeCode(daysAgo: 6 + Double($0) / 4, context: 300_000) }
        let after = (0..<20).map { claudeCode(daysAgo: Double($0) / 5, context: 120_000) }
        let result = RealizedSaving.evaluate(applied(daysAgo: 5), engine: engine, events: before + after, now: now)
        guard case .saved(let total, let monthly, let reduction) = result.status else {
            Issue.record("esperava .saved, veio \(result.status)")
            return
        }
        #expect(total > 0)
        #expect(monthly > total)
        #expect(reduction > 0.5)
    }

    @Test("Desperdício por resposta subiu: sem economia")
    func noSavingsWhenWorse() {
        let before = (0..<40).map { claudeCode(daysAgo: 6 + Double($0) / 4, context: 150_000) }
        let after = (0..<20).map { claudeCode(daysAgo: Double($0) / 5, context: 350_000) }
        let result = RealizedSaving.evaluate(applied(daysAgo: 5), engine: engine, events: before + after, now: now)
        guard case .noSavings(let change) = result.status else {
            Issue.record("esperava .noSavings, veio \(result.status)")
            return
        }
        #expect(change > 0)
    }

    @Test("Volume maior de uso não conta como economia")
    func volumeDoesNotCount() {
        // Mesmo desperdício por resposta, com o dobro de respostas depois: redução ~0.
        let before = (0..<20).map { claudeCode(daysAgo: 6 + Double($0) / 2, context: 250_000) }
        let after = (0..<40).map { claudeCode(daysAgo: Double($0) / 10, context: 250_000) }
        let result = RealizedSaving.evaluate(applied(daysAgo: 5), engine: engine, events: before + after, now: now)
        if case .saved(_, _, let reduction) = result.status {
            #expect(reduction < 0.01)
        }
    }
}
