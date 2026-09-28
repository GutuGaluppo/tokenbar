import Foundation
import Testing
@testable import TokenBar

@Suite("Dicas ao vivo")
struct LiveSessionsTests {
    let engine = LiveSessionsEngine(prices: Fixtures.prices)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Uma chamada ao modelo `secondsAgo` antes de `now`, com o contexto informado.
    private func call(_ secondsAgo: Double, context: Int, session: String = "s", model: String = "claude-sonnet-5",
                      output: Int = 1_000, cacheWrite: Int = 2_000, oneHour: Bool = false,
                      sidechain: Bool = false, cost: Double = 0.1) -> LiveInput {
        LiveInput(
            timestamp: now.addingTimeInterval(-secondsAgo), model: model, project: "demo", tool: "Claude Code (CLI)",
            session: session, isSidechain: sidechain,
            input: 100, output: output, cacheWrite: cacheWrite, cacheWrite1h: oneHour ? cacheWrite : 0,
            cacheRead: max(context - 100 - cacheWrite, 0), costUSD: cost
        )
    }

    private func session(_ events: [LiveInput], context: LiveContext = LiveContext()) throws -> LiveSession {
        try #require(engine.sessions(from: events, context: context, now: now).first)
    }

    @Test("Conversa longa sugere /compact com o custo por chamada")
    func largeContext() throws {
        let result = try session([call(600, context: 20_000), call(30, context: 120_000)])
        let tip = try #require(result.tips.first { $0.id == "context-large" })
        #expect(tip.severity == .attention)
        #expect(tip.command?.hasPrefix("/compact") == true)
        #expect(result.context == 120_000)
    }

    @Test("Perto do limite da janela a dica vira urgente e substitui a de conversa longa")
    func nearlyFull() throws {
        let result = try session([call(30, context: 170_000)])
        #expect(result.tips.first?.id == "context-full")
        #expect(result.tips.first?.severity == .urgent)
        #expect(!result.tips.contains { $0.id == "context-large" })
    }

    @Test("Contexto acima de 200k indica janela estendida")
    func extendedWindow() throws {
        let result = try session([call(30, context: 300_000)])
        #expect(result.contextWindow == LiveSessionsEngine.extendedContextWindow)
        #expect(!result.tips.contains { $0.id == "context-full" })
    }

    @Test("Subagentes não mudam o contexto da conversa principal, mas entram no custo")
    func sidechainIgnoredForContext() throws {
        let result = try session([
            call(120, context: 90_000, cost: 1),
            call(10, context: 15_000, sidechain: true, cost: 0.5),
        ])
        #expect(result.context == 90_000)
        #expect(result.calls == 1)
        #expect(abs(result.costUSD - 1.5) < 1e-9)
    }

    @Test("TTL do cache vem da última escrita: 5 min ou 1 h")
    func cacheTTL() throws {
        #expect(try session([call(30, context: 50_000)]).cacheTTL == 300)
        #expect(try session([call(30, context: 50_000, oneHour: true)]).cacheTTL == 3_600)
    }

    @Test("Avisa pouco antes do cache expirar e depois que expirou")
    func cacheTips() throws {
        let expiring = try session([call(240, context: 60_000)])     // 5 min de TTL, parado há 4 min
        #expect(expiring.tips.contains { $0.id == "cache-expiring" })

        let expired = try session([call(400, context: 60_000)])
        let tip = try #require(expired.tips.first { $0.id == "cache-expired" })
        #expect(tip.command == "/clear")

        let fresh = try session([call(30, context: 60_000)])
        #expect(!fresh.tips.contains { $0.id.hasPrefix("cache") })

        // Cache de 1 h: aos 4 min parado ainda está longe de expirar.
        let oneHour = try session([call(240, context: 60_000, oneHour: true)])
        #expect(!oneHour.tips.contains { $0.id.hasPrefix("cache") })
    }

    @Test("Frio custa mais que quente na próxima chamada")
    func callCosts() throws {
        let result = try session([call(30, context: 100_000)])
        let warm = try #require(result.warmCallCostUSD)
        let cold = try #require(result.coldCallCostUSD)
        #expect(cold > warm * 5)
    }

    @Test("Sessões paradas há muito tempo saem da lista")
    func inactiveSessionsDropped() {
        let stale = call(300 + LiveSessionsEngine.idleGrace + 60, context: 60_000)
        #expect(engine.sessions(from: [stale], context: LiveContext(), now: now).isEmpty)
    }

    @Test("Sessão do plano apertada pede para compactar")
    func planSession() throws {
        let plan = LimitStatus(kind: .planSession, used: 96, limit: 100, resetsAt: now.addingTimeInterval(3_600), periodID: "p")
        let result = try session([call(30, context: 80_000)], context: LiveContext(planSession: plan))
        let tip = try #require(result.tips.first { $0.id == "plan-session" })
        #expect(tip.severity == .urgent)
    }

    @Test("Sessão que começa pesada sugere /context")
    func heavyStart() throws {
        let result = try session([call(300, context: 55_000), call(30, context: 60_000)])
        #expect(result.tips.contains { $0.id == "heavy-start" && $0.command == "/context" })
        #expect(result.startContext == 55_000)
    }

    @Test("Sessões com dica urgente vêm primeiro")
    func ordering() {
        let events = [call(10, context: 20_000, session: "a"), call(60, context: 180_000, session: "b")]
        #expect(engine.sessions(from: events, context: LiveContext(), now: now).map(\.id) == ["b", "a"])
    }
}
