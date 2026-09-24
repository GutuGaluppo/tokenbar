import Foundation
import Testing
@testable import TokenBar

@Suite("Parser do Claude Code")
struct ClaudeCodeParserTests {
    let parser = ClaudeCodeParser(prices: Fixtures.prices, roots: [])

    private func parse(_ line: String) -> ParsedUsage? {
        var state = parser.initialState()
        return parser.parse(Fixtures.bytes(line), state: &state).usage
    }

    @Test("Extrai tokens, identificador, ferramenta e sessão de uma resposta")
    func parsesAssistantResponse() throws {
        let usage = try #require(parse(Fixtures.claudeLine(
            id: "msg_42", request: "req_7", input: 1_000, output: 500,
            cacheWrite5m: 300, cacheWrite1h: 2_000, cacheRead: 10_000, entrypoint: "claude-desktop"
        )))
        #expect(usage.externalID == "cc:msg_42:req_7")
        #expect(usage.tokens.input == 1_000)
        #expect(usage.tokens.output == 500)
        #expect(usage.tokens.cacheWrite5m == 300)
        #expect(usage.tokens.cacheWrite1h == 2_000)
        #expect(usage.tokens.cacheRead == 10_000)
        #expect(usage.tool == "Claude Code (Desktop)")
        #expect(usage.session == "session-1")
        #expect(usage.provider == .anthropic)
    }

    @Test("Calcula o custo com a tabela de preços (Sonnet 5, cache de 1 h)")
    func computesCost() throws {
        let usage = try #require(parse(Fixtures.claudeLine(input: 1_000, output: 500, cacheWrite1h: 2_000, cacheRead: 10_000)))
        // (1000×2 + 500×10 + 2000×2×2 + 10000×0,2) / 1M
        #expect(abs(usage.costUSD - 0.017) < 1e-9)
    }

    @Test("Modo fast dobra o custo no Opus 5")
    func fastModeDoublesCost() throws {
        let standard = try #require(parse(Fixtures.claudeLine(model: "claude-opus-5", input: 1_000, output: 1_000)))
        let fast = try #require(parse(Fixtures.claudeLine(model: "claude-opus-5", input: 1_000, output: 1_000, speed: "fast")))
        #expect(abs(fast.costUSD - standard.costUSD * 2) < 1e-12)
    }

    @Test("Ignora linhas que não são respostas com consumo",
          arguments: [
            Fixtures.claudeLine(type: "user"),
            Fixtures.claudeLine(model: "<synthetic>"),
            Fixtures.claudeLine(input: 0, output: 0),
            #"{"type":"summary","summary":"sem usage"}"#,
            "isto não é JSON",
          ])
    func ignoresNonUsageLines(line: String) {
        #expect(parse(line) == nil)
    }

    @Test("Modelo fora da tabela de preços fica com custo NaN (contado como sem preço)")
    func unknownModelHasNoPrice() throws {
        let usage = try #require(parse(Fixtures.claudeLine(model: "claude-desconhecido-9")))
        #expect(usage.costUSD.isNaN)
    }

    @Test("Nome de projeto pula subpastas genéricas quando a pasta não existe")
    func projectFromMissingFolder() throws {
        let usage = try #require(parse(Fixtures.claudeLine(cwd: "/nonexistent-tokenbar/meu-app/src-tauri")))
        #expect(usage.project == "meu-app")
    }
}

@Suite("Parser do Codex")
struct CodexParserTests {
    let parser = CodexParser(prices: Fixtures.prices, roots: [])

    @Test("Usa sessão e modelo de linhas anteriores e separa a entrada em cache")
    func parsesTokenCount() throws {
        var state = parser.initialState()
        _ = parser.parse(Fixtures.bytes(Fixtures.codexSessionMeta()), state: &state)
        _ = parser.parse(Fixtures.bytes(Fixtures.codexTurnContext(model: "gpt-5.4")), state: &state)
        let result = parser.parse(Fixtures.bytes(Fixtures.codexTokenCount(total: 1_500, input: 1_000, cached: 600, output: 500)), state: &state)

        let usage = try #require(result.usage)
        #expect(usage.externalID == "cx:codex-session-1:1500")
        #expect(usage.model == "gpt-5.4")
        #expect(usage.tokens.input == 400)
        #expect(usage.tokens.cacheRead == 600)
        #expect(usage.tokens.output == 500)
        #expect(usage.tool == "Codex CLI")
        #expect(usage.project == "codex-project")
        #expect(usage.provider == .openai)
    }

    @Test("Lê os limites do plano (5 h e semana)")
    func parsesRateLimits() throws {
        var state = parser.initialState()
        _ = parser.parse(Fixtures.bytes(Fixtures.codexSessionMeta()), state: &state)
        let result = parser.parse(Fixtures.bytes(Fixtures.codexTokenCount(total: 10, input: 5, cached: 0, output: 5,
                                                                           primaryUsed: 17, secondaryUsed: 74)), state: &state)
        let limits = try #require(result.limits)
        #expect(limits.planType == "plus")
        #expect(limits.windows.map(\.windowMinutes) == [300, 10_080])
        #expect(limits.windows.map(\.usedPercent) == [17, 74])
    }

    @Test("Evento só com limites (sem info) não gera consumo")
    func limitsOnlyEvent() {
        var state = parser.initialState()
        _ = parser.parse(Fixtures.bytes(Fixtures.codexSessionMeta()), state: &state)
        let result = parser.parse(Fixtures.bytes(Fixtures.codexTokenCount(total: 0, input: 0, cached: 0, output: 0, withInfo: false)), state: &state)
        #expect(result.usage == nil)
        #expect(result.limits != nil)
    }

    @Test("Sem session_meta antes, o consumo é descartado")
    func requiresSession() {
        var state = parser.initialState()
        let result = parser.parse(Fixtures.bytes(Fixtures.codexTokenCount(total: 1_500, input: 1_000, cached: 0, output: 500)), state: &state)
        #expect(result.usage == nil)
    }
}
