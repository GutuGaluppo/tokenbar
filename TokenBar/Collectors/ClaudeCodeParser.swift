import Foundation

/// Logs do Claude Code (`~/.claude/projects/**/*.jsonl`): uma linha por bloco de resposta, com o
/// `usage` da mensagem. Cada resposta aparece em várias linhas — `message.id` + `requestId` a identifica.
struct ClaudeCodeParser: JSONLLogParser {
    struct FileState: Codable {}

    var prices: PriceTable
    let roots: [URL]
    private let decoder = JSONDecoder()
    private let usageMarker = Data("\"usage\"".utf8)
    private let assistantMarker = Data("\"assistant\"".utf8)

    init(prices: PriceTable, roots: [URL] = ClaudeCodeParser.defaultRoots) {
        self.prices = prices
        self.roots = roots
    }

    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: ".claude/projects", directoryHint: .isDirectory),
            home.appending(path: ".config/claude/projects", directoryHint: .isDirectory),
        ].filter { FileManager.default.fileExists(atPath: $0.path()) }
    }

    func initialState() -> FileState { FileState() }

    private struct LogLine: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let sessionId: String?
        let cwd: String?
        let entrypoint: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
            let cache_creation: CacheCreation?
            let speed: String?
        }

        struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Int?
            let ephemeral_1h_input_tokens: Int?
        }
    }

    func parse(_ line: Data.SubSequence, state: inout FileState) -> (usage: ParsedUsage?, limits: LocalPlanLimits?) {
        // Filtro barato antes de decodificar: a maioria das linhas não é resposta do modelo.
        guard line.range(of: usageMarker) != nil, line.range(of: assistantMarker) != nil,
              let entry = try? decoder.decode(LogLine.self, from: Data(line)),
              entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let model = message.model, !model.hasPrefix("<"),   // ignora "<synthetic>"
              let messageID = message.id,
              let timestamp = entry.timestamp.flatMap(ISODate.parse)
        else { return (nil, nil) }

        let cacheWriteTotal = usage.cache_creation_input_tokens ?? 0
        let cacheWrite1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
        let tokens = TokenCounts(
            input: usage.input_tokens ?? 0,
            output: usage.output_tokens ?? 0,
            cacheWrite5m: max(cacheWriteTotal - cacheWrite1h, 0),
            cacheWrite1h: cacheWrite1h,
            cacheRead: usage.cache_read_input_tokens ?? 0
        )
        guard tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead > 0 else { return (nil, nil) }

        let cost = prices.cost(model: model, tokens: tokens, fast: usage.speed == "fast")
        let parsed = ParsedUsage(
            externalID: "cc:\(messageID):\(entry.requestId ?? "")",
            timestamp: timestamp,
            provider: prices.price(for: model)?.provider ?? .anthropic,
            model: model,
            project: entry.cwd.map(ProjectResolver.project(for:)),
            tool: Self.toolName(for: entry.entrypoint),
            session: entry.sessionId,
            tokens: tokens,
            costUSD: cost ?? .nan
        )
        return (parsed, nil)
    }

    private static func toolName(for entrypoint: String?) -> String {
        switch entrypoint {
        case "cli": "Claude Code (CLI)"
        case "claude-vscode": "Claude Code (VS Code)"
        case "claude-desktop": "Claude Code (Desktop)"
        case let value? where value.hasPrefix("sdk"): "Agent SDK"
        default: "Claude Code"
        }
    }
}
