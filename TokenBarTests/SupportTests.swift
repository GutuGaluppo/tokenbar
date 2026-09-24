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
