import Foundation

/// Logs do Claude Code (`~/.claude/projects/**/*.jsonl`): uma linha por bloco de resposta, com o
/// `usage` da mensagem. Cada resposta aparece em várias linhas — `message.id` + `requestId` a identifica.
struct ClaudeCodeParser: JSONLLogParser {
    struct FileState: Codable {}

    var prices: PriceTable
    let roots: [URL]
    /// Recebe os sinais de ferramentas, branch e compactação para as dicas ao vivo (opcional).
    let signals: SessionSignals?
    private let decoder = JSONDecoder()
    private let usageMarker = Data("\"usage\"".utf8)
    private let assistantMarker = Data("\"assistant\"".utf8)
    private let toolResultMarker = Data("\"tool_result\"".utf8)
    private let compactMarker = Data("\"compact_boundary\"".utf8)

    init(prices: PriceTable, roots: [URL] = ClaudeCodeParser.defaultRoots, signals: SessionSignals? = nil) {
        self.prices = prices
        self.roots = roots
        self.signals = signals
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
        let subtype: String?
        let timestamp: String?
        let requestId: String?
        let sessionId: String?
        let cwd: String?
        let entrypoint: String?
        let isSidechain: Bool?
        let gitBranch: String?
        let effort: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            /// Blocos da mensagem; só os de ferramenta interessam. Texto simples vira nil.
            let content: [Block]?

            enum CodingKeys: String, CodingKey { case id, model, usage, content }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decodeIfPresent(String.self, forKey: .id)
                model = try container.decodeIfPresent(String.self, forKey: .model)
                usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
                content = try? container.decodeIfPresent([Block].self, forKey: .content)
            }
        }

        /// Bloco de conteúdo. O texto só é lido para medir o tamanho e é descartado em seguida.
        struct Block: Decodable {
            let type: String?
            let id: String?
            let name: String?
            let input: Input?
            let tool_use_id: String?
            let is_error: Bool?
            let content: ResultContent?

            struct Input: Decodable {
                let file_path: String?
                let content: String?
                let offset: Int?
                let limit: Int?
            }
        }

        /// Conteúdo de um resultado de ferramenta: texto ou lista de blocos. Guarda só o tamanho.
        struct ResultContent: Decodable {
            let bytes: Int

            private struct Part: Decodable { let text: String? }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    bytes = text.utf8.count
                } else if let parts = try? container.decode([Part].self) {
                    bytes = parts.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
                } else {
                    bytes = 0
                }
            }
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
        let isResponse = line.range(of: usageMarker) != nil && line.range(of: assistantMarker) != nil
        let isSignal = signals != nil && (line.range(of: toolResultMarker) != nil || line.range(of: compactMarker) != nil)
        guard isResponse || isSignal, let entry = try? decoder.decode(LogLine.self, from: Data(line)) else { return (nil, nil) }
        if let signals { signals.record(Self.signals(from: entry)) }

        guard entry.type == "assistant",
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
            costUSD: cost ?? .nan,
            isSidechain: entry.isSidechain ?? false
        )
        return (parsed, nil)
    }

    /// Sinais para as dicas ao vivo: ferramentas chamadas e seus resultados, branch, effort e compactação.
    private static func signals(from entry: LogLine) -> [SessionSignal] {
        guard let session = entry.sessionId, let timestamp = entry.timestamp.flatMap(ISODate.parse) else { return [] }
        let sidechain = entry.isSidechain ?? false
        func signal(_ kind: SessionSignal.Kind) -> SessionSignal {
            SessionSignal(session: session, timestamp: timestamp, isSidechain: sidechain, kind: kind)
        }

        if entry.type == "system" {
            return entry.subtype == "compact_boundary" ? [signal(.compacted)] : []
        }
        var result: [SessionSignal] = []
        if entry.type == "assistant", let id = entry.message?.id {
            result.append(signal(.response(messageID: id, effort: entry.effort, branch: entry.gitBranch)))
        }
        for block in entry.message?.content ?? [] {
            switch block.type {
            case "tool_use":
                guard let id = block.id, let name = block.name else { continue }
                let input = block.input
                // Só leituras inteiras contam como releitura; trechos (offset/limit) são o uso recomendado.
                let wholeFile = name == "Write" || (name == "Read" && input?.offset == nil && input?.limit == nil)
                let target = wholeFile ? input?.file_path.map(\.hashValue) : nil
                let writeTokens = name == "Write" ? (input?.content?.utf8.count ?? 0) / 4 : 0
                result.append(signal(.toolUse(id: id, name: name, target: target, writeTokens: writeTokens)))
            case "tool_result":
                guard let id = block.tool_use_id else { continue }
                result.append(signal(.toolResult(toolUseID: id, tokens: (block.content?.bytes ?? 0) / 4, isError: block.is_error ?? false)))
            default:
                continue
            }
        }
        return result
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
