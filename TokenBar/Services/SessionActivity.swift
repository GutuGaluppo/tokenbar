import Foundation

/// O que os sinais de uma sessão dizem sobre o jeito de trabalhar nela, desde a última compactação
/// (o que veio antes já saiu do contexto). Só a conversa principal conta; subagentes têm contexto próprio.
struct SessionActivity: Equatable {
    struct LargeResult: Equatable {
        let tool: String
        let tokens: Int
        let at: Date
    }

    struct BranchChange: Equatable {
        let from: String
        let to: String
        let at: Date
    }

    /// Maior resultado de ferramenta dos últimos minutos.
    var largestRecentResult: LargeResult?
    /// Quantas vezes o arquivo mais relido entrou inteiro no contexto.
    var maxWholeFileReads = 0
    /// Resultados com erro seguidos, no fim da sessão.
    var trailingErrors = 0
    var lastErrorAt: Date?
    /// Troca de branch dentro da mesma conversa.
    var branchChange: BranchChange?
    /// Leituras e buscas recentes na conversa principal.
    var recentExploration = 0
    /// Maior número de vezes que um mesmo arquivo foi reescrito inteiro (Write grande).
    var maxRewrites = 0
    /// Effort das últimas respostas, da mais antiga para a mais recente.
    var recentEfforts: [String] = []
    var lastCompaction: Date?

    static let recentResultWindow: TimeInterval = 10 * 60
    static let explorationWindow: TimeInterval = 15 * 60
    static let explorationTools: Set<String> = ["Read", "Grep", "Glob", "LS"]
    /// Um Write abaixo disso é arquivo pequeno; reescrever não pesa.
    static let largeWriteTokens = 2_000

    init() {}

    init(signals: [SessionSignal], now: Date, recentResponses: Int = LiveSessionsEngine.recentCalls) {
        let ordered = signals.filter { !$0.isSidechain }.sorted { $0.timestamp < $1.timestamp }
        let lastCompaction = ordered.last { $0.kind == .compacted }?.timestamp
        self.lastCompaction = lastCompaction
        let current = ordered.filter { lastCompaction == nil || $0.timestamp > lastCompaction! }

        var toolNames: [String: String] = [:]
        var reads: [Int: Int] = [:]
        var rewrites: [Int: Int] = [:]
        var seenTools: Set<String> = []
        var seenResponses: Set<String> = []
        var efforts: [String] = []
        var branch: String?

        for signal in current {
            switch signal.kind {
            case let .toolUse(id, name, target, writeTokens):
                // A mesma chamada pode aparecer em mais de uma linha do log.
                guard seenTools.insert(id).inserted else { continue }
                toolNames[id] = name
                if name == "Read", let target { reads[target, default: 0] += 1 }
                if name == "Write", let target, writeTokens >= Self.largeWriteTokens { rewrites[target, default: 0] += 1 }
                if Self.explorationTools.contains(name), now.timeIntervalSince(signal.timestamp) <= Self.explorationWindow {
                    recentExploration += 1
                }
            case let .toolResult(id, tokens, isError):
                if isError {
                    trailingErrors += 1
                    lastErrorAt = signal.timestamp
                } else {
                    trailingErrors = 0
                }
                if now.timeIntervalSince(signal.timestamp) <= Self.recentResultWindow,
                   tokens > (largestRecentResult?.tokens ?? 0) {
                    largestRecentResult = LargeResult(tool: toolNames[id] ?? "?", tokens: tokens, at: signal.timestamp)
                }
            case let .response(messageID, effort, newBranch):
                guard seenResponses.insert(messageID).inserted else { continue }
                if let effort { efforts.append(effort) }
                if let newBranch, !newBranch.isEmpty {
                    if let branch, branch != newBranch {
                        branchChange = BranchChange(from: branch, to: newBranch, at: signal.timestamp)
                    }
                    branch = newBranch
                }
            case .compacted:
                continue
            }
        }
        maxWholeFileReads = reads.values.max() ?? 0
        maxRewrites = rewrites.values.max() ?? 0
        recentEfforts = Array(efforts.suffix(recentResponses))
    }
}
