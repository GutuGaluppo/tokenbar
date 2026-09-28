import Foundation
import Testing
@testable import TokenBar

@Suite("Dicas ao vivo: Codex, economia e barra de status")
struct LiveTipsF3Tests {
    let engine = LiveSessionsEngine(prices: Fixtures.prices)
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func call(_ secondsAgo: Double, context: Int, model: String = "claude-sonnet-5", codex: Bool = false) -> LiveInput {
        LiveInput(timestamp: now.addingTimeInterval(-secondsAgo), model: model, project: "p", tool: nil, session: "s",
                  isSidechain: false, input: 100, output: 500, cacheWrite: codex ? 0 : 1_000, cacheWrite1h: 0,
                  cacheRead: max(context - (codex ? 100 : 1_100), 0), costUSD: 0.1, isCodex: codex)
    }

    // MARK: - Codex

    @Test("Sessão do Codex usa /compact, /new e /status e não recebe dica de cache")
    func codexCommands() throws {
        var activity = SessionActivity()
        activity.contextWindow = 258_400
        let session = try #require(engine.sessions(
            from: [call(300, context: 50_000, codex: true), call(400, context: 45_000, codex: true)],
            activity: ["s": activity], context: LiveContext(), now: now
        ).first)
        #expect(session.isCodex)
        #expect(session.contextWindow == 258_400)
        #expect(!session.tips.contains { $0.id.hasPrefix("cache") })
        #expect(session.tips.first { $0.id == "heavy-start" }?.command == "/status")

        let large = try #require(engine.sessions(from: [call(30, context: 150_000, codex: true)], context: LiveContext(), now: now).first)
        #expect(large.tips.first { $0.id == "context-large" }?.command == "/compact")
        #expect(large.clearCommand == "/new")
    }

    @Test("Limite de sessão do Codex vale para sessões do Codex, não do Claude")
    func codexPlanLimit() throws {
        let codexLimit = LimitStatus(kind: .codexSession, used: 90, limit: 100, resetsAt: nil, periodID: "c")
        let context = LiveContext(codexSession: codexLimit)
        let codex = try #require(engine.sessions(from: [call(30, context: 80_000, codex: true)], context: context, now: now).first)
        #expect(codex.tips.contains { $0.id == "plan-session" })
        let claude = try #require(engine.sessions(from: [call(30, context: 80_000)], context: context, now: now).first)
        #expect(!claude.tips.contains { $0.id == "plan-session" })
    }

    @Test("Parser do Codex informa a janela de contexto")
    func codexContextWindow() {
        let signals = SessionSignals(maxAge: .infinity)
        let parser = CodexParser(prices: Fixtures.prices, roots: [], signals: signals)
        var state = parser.initialState()
        for line in [Fixtures.codexSessionMeta(), Fixtures.codexTurnContext(),
                     Fixtures.codexTokenCount(total: 100, input: 80, cached: 40, output: 20, contextWindow: 258_400)] {
            _ = parser.parse(Fixtures.bytes(line), state: &state)
        }
        #expect(signals.signals(for: ["codex-session-1"])["codex-session-1"]?.map(\.kind) == [.contextWindow(258_400)])
    }

    // MARK: - Economia

    @Test("Compactação depois da dica conta a releitura evitada até a próxima queda")
    func savingsAfterTip() throws {
        let price = try #require(Fixtures.prices.price(for: "claude-sonnet-5"))
        let calls = [call(600, context: 150_000), call(500, context: 30_000), call(400, context: 35_000),
                     call(300, context: 40_000)]
        let saved = LiveSavings.saved(main: calls, tipShownAt: now.addingTimeInterval(-650), prices: Fixtures.prices)
        // 120k tokens a menos em 3 chamadas.
        #expect(abs(saved - 3 * 120_000 * price.cacheRead / 1_000_000) < 1e-9)
    }

    @Test("Queda antes da dica não conta")
    func savingsBeforeTip() {
        let calls = [call(600, context: 150_000), call(500, context: 30_000), call(400, context: 35_000)]
        #expect(LiveSavings.saved(main: calls, tipShownAt: now.addingTimeInterval(-450), prices: Fixtures.prices) == 0)
    }

    @Test("Livro de economia só cresce e esquece sessões com mais de 30 dias")
    func ledger() {
        var ledger = LiveSavingsLedger()
        let first = ledger.update(session: "a", savedUSD: 1, now: now)
        let lower = ledger.update(session: "a", savedUSD: 0.5, now: now)
        let later = ledger.update(session: "b", savedUSD: 2, now: now.addingTimeInterval(31 * 86_400))
        #expect(first && !lower && later)
        #expect(ledger.total == 2)
    }

    // MARK: - Barra de status

    @Test("Linha da barra de status: dica principal com o comando, ou o contexto")
    func statusLine() throws {
        let urgent = try #require(engine.sessions(from: [call(30, context: 170_000)], context: LiveContext(), now: now).first)
        let line = StatusLineBridge.line(for: urgent)
        #expect(line.hasPrefix("⚠︎"))
        #expect(line.contains("→ /compact"))
        #expect(line.hasSuffix("170k/200k"))

        let calm = try #require(engine.sessions(from: [call(30, context: 20_000)], context: LiveContext(), now: now).first)
        #expect(StatusLineBridge.line(for: calm).hasPrefix("TokenBar · 20k/200k"))
    }
}

@Suite("Script da barra de status")
struct StatusLineScriptTests {
    /// Roda o script como o Claude Code faria: JSON na entrada, linha na saída.
    private func run(_ script: URL, input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = [script.path(percentEncoded: false)]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("Imprime a linha da sessão e ignora ids inválidos ou linhas velhas")
    func script() throws {
        let directory = try Fixtures.temporaryDirectory().appending(path: "Application Support/TokenBar", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "live"), withIntermediateDirectories: true)
        let script = directory.appending(path: "statusline.sh")
        try StatusLineBridge.script.write(to: script, atomically: true, encoding: .utf8)
        let line = directory.appending(path: "live/abc-123.txt")
        try "⚠︎ Contexto quase cheio (87%) → /compact · 174k/200k\n".write(to: line, atomically: true, encoding: .utf8)

        let json = #"{"session_id": "abc-123", "model": {"id": "claude-opus-5-5"}, "cwd": "/tmp"}"#
        #expect(try run(script, input: json) == "⚠︎ Contexto quase cheio (87%) → /compact · 174k/200k\n")
        #expect(try run(script, input: #"{"session_id":"../../etc/passwd"}"#).isEmpty)
        #expect(try run(script, input: #"{"session_id":"outra"}"#).isEmpty)

        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3_600)], ofItemAtPath: line.path(percentEncoded: false))
        #expect(try run(script, input: json).isEmpty)
    }
}
