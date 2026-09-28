import Foundation
import Testing
@testable import TokenBar

@Suite("Sinais das sessões do Claude Code")
struct SessionSignalsTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ secondsAgo: Double) -> String {
        now.addingTimeInterval(-secondsAgo).formatted(.iso8601)
    }

    /// Sinais que o parser grava para uma linha de log.
    private func parse(_ lines: [String]) -> [SessionSignal] {
        let signals = SessionSignals(maxAge: .infinity)
        let parser = ClaudeCodeParser(prices: Fixtures.prices, roots: [], signals: signals)
        var state = parser.initialState()
        for line in lines { _ = parser.parse(Fixtures.bytes(line), state: &state) }
        return signals.signals(for: ["s"])["s"] ?? []
    }

    private func toolUseLine(id: String, name: String, input: [String: Any], messageID: String = "msg_1",
                             branch: String = "main", effort: String = "medium") -> String {
        Fixtures.json([
            "type": "assistant", "timestamp": iso(60), "sessionId": "s", "requestId": "r", "isSidechain": false,
            "gitBranch": branch, "effort": effort, "cwd": "/nonexistent-tokenbar/p",
            "message": [
                "id": messageID, "model": "claude-sonnet-5",
                "content": [["type": "tool_use", "id": id, "name": name, "input": input]],
                "usage": ["input_tokens": 10, "output_tokens": 50],
            ],
        ])
    }

    private func toolResultLine(id: String, content: Any, isError: Bool = false) -> String {
        Fixtures.json([
            "type": "user", "timestamp": iso(50), "sessionId": "s", "isSidechain": false,
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content, "is_error": isError]]],
        ])
    }

    // MARK: - Parser

    @Test("Chamada de ferramenta vira sinal com o hash do arquivo, sem o conteúdo")
    func toolUse() throws {
        let signals = parse([
            toolUseLine(id: "t1", name: "Read", input: ["file_path": "/a.swift"], messageID: "m1"),
            toolUseLine(id: "t2", name: "Read", input: ["file_path": "/a.swift", "offset": 10, "limit": 20], messageID: "m2"),
            toolUseLine(id: "t3", name: "Write", input: ["file_path": "/b.swift", "content": String(repeating: "x", count: 8_000)], messageID: "m3"),
        ])
        let uses = signals.compactMap { signal -> (String, Int?, Int)? in
            if case let .toolUse(_, name, target, tokens) = signal.kind { return (name, target, tokens) }
            return nil
        }
        #expect(uses.count == 3)
        #expect(uses[0].1 == "/a.swift".hashValue)
        #expect(uses[1].1 == nil)          // trecho do arquivo não conta como releitura
        #expect(uses[2].2 == 2_000)        // 8.000 bytes ≈ 2.000 tokens
        #expect(signals.contains { $0.kind == .response(messageID: "m1", effort: "medium", branch: "main") })
    }

    @Test("Resultado de ferramenta guarda só o tamanho e o erro", arguments: [true, false])
    func toolResult(asBlocks: Bool) throws {
        let text = String(repeating: "y", count: 4_000)
        let content: Any = asBlocks ? [["type": "text", "text": text]] : text
        let signals = parse([toolResultLine(id: "t1", content: content, isError: true)])
        #expect(signals == [SessionSignal(session: "s", timestamp: try #require(ISODate.parse(iso(50))), isSidechain: false,
                                          kind: .toolResult(toolUseID: "t1", tokens: 1_000, isError: true))])
    }

    @Test("Compactação vira sinal")
    func compaction() {
        let line = Fixtures.json(["type": "system", "subtype": "compact_boundary", "timestamp": iso(10),
                                  "sessionId": "s", "content": "Conversation compacted"])
        #expect(parse([line]).map(\.kind) == [.compacted])
    }

    @Test("Prompt de texto do usuário não gera sinal nem quebra a leitura")
    func plainUserPrompt() {
        let line = Fixtures.json(["type": "user", "timestamp": iso(10), "sessionId": "s",
                                  "message": ["role": "user", "content": "explique o tool_result"]])
        #expect(parse([line]).isEmpty)
    }

    @Test("Sinais antigos (ex.: reimportação) são descartados")
    func dropsOldSignals() {
        let clock = now
        let signals = SessionSignals(maxAge: 3_600, clock: { clock })
        signals.record([
            SessionSignal(session: "s", timestamp: now.addingTimeInterval(-7_200), isSidechain: false, kind: .compacted),
            SessionSignal(session: "s", timestamp: now.addingTimeInterval(-60), isSidechain: false, kind: .compacted),
        ])
        #expect(signals.signals(for: ["s"])["s"]?.count == 1)
    }

    // MARK: - Resumo da sessão

    private func signal(_ secondsAgo: Double, _ kind: SessionSignal.Kind, sidechain: Bool = false) -> SessionSignal {
        SessionSignal(session: "s", timestamp: now.addingTimeInterval(-secondsAgo), isSidechain: sidechain, kind: kind)
    }

    @Test("Conta erros seguidos no fim e zera com um acerto")
    func trailingErrors() {
        var signals = (0..<5).map { signal(100 - Double($0), .toolResult(toolUseID: "e\($0)", tokens: 10, isError: true)) }
        #expect(SessionActivity(signals: signals, now: now).trailingErrors == 5)
        signals.append(signal(10, .toolResult(toolUseID: "ok", tokens: 10, isError: false)))
        #expect(SessionActivity(signals: signals, now: now).trailingErrors == 0)
    }

    @Test("Compactação zera o que veio antes")
    func compactionResets() {
        let read = { (id: String, ago: Double) in self.signal(ago, .toolUse(id: id, name: "Read", target: 1, writeTokens: 0)) }
        let before = [read("a", 300), read("b", 290), read("c", 280)]
        #expect(SessionActivity(signals: before, now: now).maxWholeFileReads == 3)
        let after = before + [signal(200, .compacted), read("d", 100)]
        #expect(SessionActivity(signals: after, now: now).maxWholeFileReads == 1)
    }

    @Test("Detecta troca de branch, maior resultado recente e ignora subagentes")
    func activitySummary() {
        let activity = SessionActivity(signals: [
            signal(300, .response(messageID: "m1", effort: "high", branch: "main")),
            signal(200, .toolUse(id: "t1", name: "Bash", target: nil, writeTokens: 0)),
            signal(190, .toolResult(toolUseID: "t1", tokens: 22_000, isError: false)),
            signal(150, .toolResult(toolUseID: "x", tokens: 90_000, isError: false), sidechain: true),
            signal(100, .response(messageID: "m2", effort: "high", branch: "feature/x")),
        ], now: now)
        #expect(activity.branchChange?.from == "main")
        #expect(activity.branchChange?.to == "feature/x")
        #expect(activity.largestRecentResult == .init(tool: "Bash", tokens: 22_000, at: now.addingTimeInterval(-190)))
        #expect(activity.recentEfforts == ["high", "high"])
    }

    // MARK: - Regras

    let engine = LiveSessionsEngine(prices: Fixtures.prices)

    private func call(_ secondsAgo: Double, context: Int = 80_000, model: String = "claude-sonnet-5",
                      output: Int = 500, cacheWrite: Int = 1_000, cacheRead: Int? = nil) -> LiveInput {
        LiveInput(timestamp: now.addingTimeInterval(-secondsAgo), model: model, project: "p", tool: nil, session: "s",
                  isSidechain: false, input: 100, output: output, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite,
                  cacheRead: cacheRead ?? max(context - 100 - cacheWrite, 0), costUSD: 0.1)
    }

    private func tips(_ calls: [LiveInput], _ activity: SessionActivity = SessionActivity()) -> [String] {
        engine.sessions(from: calls, activity: ["s": activity], context: LiveContext(), now: now).first?.tips.map(\.id) ?? []
    }

    @Test("Loop de erro, resultado enorme, releitura, reescrita, exploração e branch geram dicas")
    func activityRules() {
        var activity = SessionActivity()
        activity.trailingErrors = 4
        activity.lastErrorAt = now.addingTimeInterval(-60)
        activity.largestRecentResult = .init(tool: "Read", tokens: 40_000, at: now)
        activity.maxWholeFileReads = 3
        activity.maxRewrites = 2
        activity.recentExploration = 25
        activity.branchChange = .init(from: "main", to: "fix/login", at: now)
        let ids = tips([call(30)], activity)
        for id in ["error-loop", "large-result", "repeated-reads", "rewrites", "exploration", "branch-change"] {
            #expect(ids.contains(id), "faltou \(id)")
        }
    }

    @Test("Troca de modelo com cache perdido")
    func modelSwitch() {
        let calls = [call(120, context: 90_000, model: "claude-opus-5-5"),
                     call(30, context: 90_000, cacheWrite: 89_900, cacheRead: 0)]
        #expect(tips(calls).contains("model-switch"))
    }

    @Test("Opus em passos curtos sugere o Sonnet")
    func opusMechanical() {
        let calls = (0..<12).map { call(Double(600 - $0 * 30), context: 40_000, model: "claude-opus-5-5", output: 300) }
        #expect(tips(calls).contains("opus-mechanical"))
        let long = (0..<12).map { call(Double(600 - $0 * 30), context: 40_000, model: "claude-opus-5-5", output: 3_000) }
        #expect(!tips(long).contains("opus-mechanical"))
    }

    @Test("Effort alto em respostas curtas")
    func highEffort() {
        var activity = SessionActivity()
        activity.recentEfforts = Array(repeating: "xhigh", count: LiveSessionsEngine.recentCalls)
        let calls = (0..<LiveSessionsEngine.recentCalls).map { call(Double(600 - $0 * 30), context: 40_000, output: 400) }
        #expect(tips(calls, activity).contains("high-effort"))
    }
}
