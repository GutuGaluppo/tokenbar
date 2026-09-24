import Foundation

/// Logs do Codex (`~/.codex/sessions/AAAA/MM/DD/rollout-*.jsonl`). A sessão e o modelo aparecem em
/// linhas `session_meta` / `turn_context`; o consumo vem em eventos `token_count`, que trazem o uso
/// da última requisição, o total acumulado da sessão e os limites do plano (5 h e semanal).
struct CodexParser: JSONLLogParser {
    struct FileState: Codable {
        var session: String?
        var model: String?
        var project: String?
        var originator: String?
    }

    let prices: PriceTable
    let roots: [URL]
    private let decoder = JSONDecoder()
    private let markers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }

    init(prices: PriceTable, roots: [URL] = CodexParser.defaultRoots) {
        self.prices = prices
        self.roots = roots
    }

    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: ".codex/sessions", directoryHint: .isDirectory)]
            .filter { FileManager.default.fileExists(atPath: $0.path()) }
    }

    func initialState() -> FileState { FileState() }

    private struct Line: Decodable {
        let timestamp: String?
        let type: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let type: String?
        let id: String?
        let session_id: String?
        let cwd: String?
        let originator: String?
        let model: String?
        let info: Info?
        let rate_limits: RateLimits?
    }

    private struct Info: Decodable {
        let total_token_usage: Usage?
        let last_token_usage: Usage?
    }

    private struct Usage: Decodable {
        let input_tokens: Int?
        let cached_input_tokens: Int?
        let output_tokens: Int?
        let total_tokens: Int?
    }

    private struct RateLimits: Decodable {
        struct Window: Decodable {
            let used_percent: Double?
            let window_minutes: Int?
            let resets_at: Double?   // Unix, segundos
        }
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }

    func parse(_ line: Data.SubSequence, state: inout FileState) -> (usage: ParsedUsage?, limits: LocalPlanLimits?) {
        guard markers.contains(where: { line.range(of: $0) != nil }),
              let entry = try? decoder.decode(Line.self, from: Data(line)),
              let payload = entry.payload
        else { return (nil, nil) }

        switch entry.type {
        case "session_meta":
            state.session = payload.session_id ?? payload.id ?? state.session
            state.originator = payload.originator ?? state.originator
            if let cwd = payload.cwd { state.project = ProjectResolver.project(for: cwd) }
            return (nil, nil)
        case "turn_context":
            state.model = payload.model ?? state.model
            if let cwd = payload.cwd { state.project = ProjectResolver.project(for: cwd) }
            return (nil, nil)
        default:
            break
        }

        guard payload.type == "token_count", let timestamp = entry.timestamp.flatMap(ISODate.parse) else { return (nil, nil) }

        var limits: LocalPlanLimits?
        if let rateLimits = payload.rate_limits {
            let windows = [rateLimits.primary, rateLimits.secondary].compactMap { window -> LocalPlanLimits.Window? in
                guard let window, let used = window.used_percent, let minutes = window.window_minutes else { return nil }
                return .init(windowMinutes: minutes, usedPercent: used,
                             resetsAt: window.resets_at.map { Date(timeIntervalSince1970: $0) })
            }
            if !windows.isEmpty {
                limits = LocalPlanLimits(observedAt: timestamp, planType: rateLimits.plan_type, windows: windows)
            }
        }

        // O mesmo total acumulado pode ser emitido mais de uma vez: ele identifica a requisição.
        guard let last = payload.info?.last_token_usage,
              let total = payload.info?.total_token_usage?.total_tokens,
              let session = state.session
        else { return (nil, limits) }

        let input = last.input_tokens ?? 0
        let cached = min(last.cached_input_tokens ?? 0, input)
        let tokens = TokenCounts(input: input - cached, output: last.output_tokens ?? 0, cacheRead: cached)
        guard tokens.input + tokens.output + tokens.cacheRead > 0 else { return (nil, limits) }

        let model = state.model ?? "codex"
        let usage = ParsedUsage(
            externalID: "cx:\(session):\(total)",
            timestamp: timestamp,
            provider: .openai,
            model: model,
            project: state.project,
            tool: Self.toolName(for: state.originator),
            session: session,
            tokens: tokens,
            costUSD: prices.cost(model: model, tokens: tokens) ?? .nan
        )
        return (usage, limits)
    }

    private static func toolName(for originator: String?) -> String {
        switch originator {
        case "codex_vscode": "Codex (VS Code)"
        case "codex_cli_rs": "Codex CLI"
        case "Codex Desktop": "Codex (Desktop)"
        case "zed": "Codex (Zed)"
        default: "Codex"
        }
    }
}
