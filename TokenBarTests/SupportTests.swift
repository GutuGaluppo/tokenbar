import Foundation
import Testing
@testable import TokenBar

@Suite("Tabela de preços")
struct PriceTableTests {
    let prices = Fixtures.prices

    @Test("Casa pelo prefixo mais longo", arguments: [
        ("claude-opus-5-5", "claude-opus-5-5"),
        ("claude-opus-5-5-20260801", "claude-opus-5-5"),
        ("claude-opus-5", "claude-opus-5"),
        ("claude-fable-5-1", "claude-fable-5-1"),
        ("claude-sonnet-5", "claude-sonnet-5"),
    ])
    func longestPrefix(model: String, expected: String) {
        #expect(prices.price(for: model)?.match == expected)
    }

    @Test("Modelo desconhecido não tem preço")
    func unknownModel() {
        #expect(prices.price(for: "gpt-5.4") == nil)
        #expect(prices.cost(model: "gpt-5.4", tokens: TokenCounts(input: 1_000)) == nil)
    }

    @Test("Escrita de cache: 1,25× (5 min) e 2× (1 h) do preço de entrada")
    func cacheWriteMultipliers() throws {
        let fiveMinutes = try #require(prices.cost(model: "claude-sonnet-5", tokens: TokenCounts(cacheWrite5m: 1_000_000)))
        let oneHour = try #require(prices.cost(model: "claude-sonnet-5", tokens: TokenCounts(cacheWrite1h: 1_000_000)))
        #expect(abs(fiveMinutes - 2.5) < 1e-9)
        #expect(abs(oneHour - 4.0) < 1e-9)
    }
}

@Suite("Nome do projeto pela raiz git")
struct ProjectResolverTests {
    @Test("Subpasta de um repositório vira o nome da raiz")
    func subfolderOfRepository() throws {
        let root = try Fixtures.temporaryDirectory().appending(path: "repo-alpha")
        let sub = root.appending(path: "apps/web")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(ProjectResolver.project(for: sub.path()) == "repo-alpha")
    }

    @Test("Worktree conta como o repositório principal")
    func worktree() throws {
        let worktree = try Fixtures.temporaryDirectory().appending(path: "feature-x")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: /Users/alguem/code/repo-principal/.git/worktrees/feature-x\n"
            .write(to: worktree.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(ProjectResolver.project(for: worktree.path()) == "repo-principal")
    }

    @Test("Pasta que não existe mais pula nomes genéricos", arguments: [
        ("/nonexistent-tokenbar/loja/web", "loja"),
        ("/nonexistent-tokenbar/app-desktop/src-tauri", "app-desktop"),
        ("/nonexistent-tokenbar/monorepo/apps/web", "monorepo"),
        ("/nonexistent-tokenbar/ferramenta", "ferramenta"),
    ])
    func missingFolder(path: String, expected: String) {
        #expect(ProjectResolver.project(for: path) == expected)
    }
}

@Suite("Formatação e limites")
struct FormattingTests {
    @Test("Números compactos")
    func compactNumbers() {
        #expect(TokenFormat.compact(950) == "950")
        #expect(TokenFormat.compact(12_345).hasPrefix("12") && TokenFormat.compact(12_345).hasSuffix("k"))
        #expect(TokenFormat.compact(1_234_567).hasPrefix("1") && TokenFormat.compact(1_234_567).hasSuffix("M"))
        #expect(TokenFormat.compact(3_000_000_000).hasSuffix("B"))
    }

    @Test("Porcentagem restante nunca fica negativa")
    func remainingFraction() {
        let partial = LimitStatus(kind: .dailyCost, used: 30, limit: 100, resetsAt: nil, periodID: "d")
        let over = LimitStatus(kind: .dailyCost, used: 150, limit: 100, resetsAt: nil, periodID: "d")
        #expect(abs(partial.remainingFraction - 0.7) < 1e-9)
        #expect(over.remainingFraction == 0)
    }
}

@Suite("Origem da tabela de preços")
struct PriceSelectionTests {
    private func table(_ asOf: String, input: Double = 2) -> PriceTable {
        PriceTable(asOf: asOf, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2, models: [
            ModelPrice(match: "claude-sonnet-5", provider: .anthropic, input: input, output: 10, cacheRead: 0.2, fastMultiplier: nil),
        ])
    }

    @Test("prices.json do usuário sempre vence")
    func userWins() {
        let result = PriceTable.select(user: table("2020-01-01"), remote: table("2030-01-01"), bundled: table("2026-06-24"))
        #expect(result.source == .user)
    }

    @Test("Remota só vence se for mais recente que a embutida")
    func newestWins() {
        #expect(PriceTable.select(user: nil, remote: table("2026-09-01"), bundled: table("2026-06-24")).source == .remote)
        #expect(PriceTable.select(user: nil, remote: table("2026-06-24"), bundled: table("2026-06-24")).source == .bundled)
        // Remota antiga (app atualizado com tabela nova embutida) não volta a valer.
        #expect(PriceTable.select(user: nil, remote: table("2026-01-01"), bundled: table("2026-06-24")).source == .bundled)
    }

    @Test("Tabela embutida no app é válida")
    func bundledIsValid() {
        #expect(Fixtures.prices.isValid)
    }

    @Test("Tabela remota inválida é recusada", arguments: [
        PriceTable(asOf: "2026-09-01", cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2, models: []),
        PriceTable(asOf: "x", cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2, models: [
            ModelPrice(match: "a", provider: .anthropic, input: 1, output: 1, cacheRead: 1, fastMultiplier: nil)]),
        PriceTable(asOf: "2026-09-01", cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2, models: [
            ModelPrice(match: "a", provider: .anthropic, input: -1, output: 1, cacheRead: 1, fastMultiplier: nil)]),
        PriceTable(asOf: "2026-09-01", cacheWrite5mMultiplier: 50, cacheWrite1hMultiplier: 2, models: [
            ModelPrice(match: "a", provider: .anthropic, input: 1, output: 1, cacheRead: 1, fastMultiplier: nil)]),
    ])
    func invalidTables(table: PriceTable) {
        #expect(!table.isValid)
    }
}

@Suite("Exportação CSV")
struct CSVExporterTests {
    private func row(_ id: String, project: String? = "loja", cost: Double = 0.017) -> CSVExporter.Row {
        CSVExporter.Row(timestamp: Date(timeIntervalSince1970: 1_790_000_000), externalID: id, provider: "Anthropic",
                        model: "claude-sonnet-5", project: project, tool: "Claude Code (CLI)", session: "s1",
                        input: 1_000, output: 500, cacheWrite: 2_000, cacheRead: 10_000, costUSD: cost)
    }

    @Test("Cabeçalho e uma linha com ponto decimal e data ISO")
    func formatsRow() {
        let lines = CSVExporter.csv([row("cc:msg_1:req_1")]).split(separator: "\n").map(String.init)
        #expect(lines[0] == CSVExporter.header.joined(separator: ","))
        #expect(lines[1] == "2026-09-21T14:13:20Z,Claude Code,Anthropic,claude-sonnet-5,loja,Claude Code (CLI),s1,1000,500,2000,10000,0.017000")
    }

    @Test("Campos com vírgula ou aspas vêm entre aspas")
    func escapesFields() {
        #expect(CSVExporter.escape("simples") == "simples")
        #expect(CSVExporter.escape("a,b") == "\"a,b\"")
        #expect(CSVExporter.escape("diz \"oi\"") == "\"diz \"\"oi\"\"\"")
        let line = CSVExporter.csv([row("cc:x:y", project: "Retiro, 2026")]).split(separator: "\n")[1]
        #expect(line.contains(",\"Retiro, 2026\","))
    }

    @Test("Fonte pelo prefixo do identificador", arguments: [
        ("cc:a:b", "Claude Code"), ("cx:s:1", "Codex"), ("ant:u:x", "API Anthropic"), ("oai:c:1", "API OpenAI"), ("local:1", "Outro"),
    ])
    func sources(id: String, expected: String) {
        // "Outro" é traduzido; os nomes de ferramenta não.
        #expect(CSVExporter.source(for: id) == (expected == "Outro" ? String(localized: "Outro") : expected))
    }
}

@Suite("Aviso no ícone da barra")
struct MenuBarWarningTests {
    let limits = [
        LimitStatus(kind: .planSession, used: 57, limit: 100, resetsAt: nil, periodID: "s"),
        LimitStatus(kind: .planWeek, used: 90, limit: 100, resetsAt: nil, periodID: "w"),
    ]

    @Test("Com a sessão do plano na barra, o aviso segue só a sessão")
    func followsSession() throws {
        let limit = try #require(MenuBarDisplay.planSessionRemaining.warningLimit(in: limits))
        #expect(limit.kind == .planSession)
        #expect(limit.fraction < MenuBarDisplay.warningThreshold)
    }

    @Test("Nos outros modos, o aviso segue o limite mais próximo", arguments: [
        MenuBarDisplay.tokensToday, .costToday, .iconOnly, .nearestLimit, .nearestLimitUsed,
    ])
    func followsNearest(display: MenuBarDisplay) throws {
        let limit = try #require(display.warningLimit(in: limits))
        #expect(limit.kind == .planWeek)
        #expect(limit.fraction >= MenuBarDisplay.warningThreshold)
    }

    @Test("Sem limites, sem aviso")
    func noLimits() {
        #expect(MenuBarDisplay.planSessionUsed.warningLimit(in: []) == nil)
    }
}
