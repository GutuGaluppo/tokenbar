import Foundation
import Synchronization

/// Um fato sobre o que acontece numa sessão do Claude Code, além dos tokens: ferramenta chamada,
/// resultado, branch, compactação. Só metadados — nada do texto da conversa.
struct SessionSignal: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// Chamada de ferramenta. `target` é um hash do arquivo (só leituras inteiras e escritas);
        /// `writeTokens` estima o tamanho do conteúdo gravado por um Write.
        case toolUse(id: String, name: String, target: Int?, writeTokens: Int)
        /// Resultado de ferramenta, com o tamanho estimado em tokens.
        case toolResult(toolUseID: String, tokens: Int, isError: Bool)
        /// Resposta do modelo: effort pedido e branch git do momento.
        case response(messageID: String, effort: String?, branch: String?)
        /// A conversa foi compactada (`/compact` ou automática).
        case compacted
    }

    let session: String
    let timestamp: Date
    let isSidechain: Bool
    let kind: Kind
}

/// Guarda em memória os sinais recentes de cada sessão, para as dicas ao vivo. Nada vai para o banco
/// nem para o disco; sinais antigos (ex.: de uma reimportação do histórico) são descartados.
final class SessionSignals: Sendable {
    /// Sinais mais velhos que isso não interessam às dicas ao vivo.
    let maxAge: TimeInterval
    private let clock: @Sendable () -> Date
    private let storage = Mutex<[String: [SessionSignal]]>([:])
    private static let maxPerSession = 2_000

    init(maxAge: TimeInterval = 3 * 3_600, clock: @escaping @Sendable () -> Date = { .now }) {
        self.maxAge = maxAge
        self.clock = clock
    }

    func record(_ signals: [SessionSignal]) {
        let cutoff = clock().addingTimeInterval(-maxAge)
        let fresh = signals.filter { $0.timestamp >= cutoff }
        guard !fresh.isEmpty else { return }
        storage.withLock { sessions in
            for signal in fresh {
                sessions[signal.session, default: []].append(signal)
            }
            for id in Set(fresh.map(\.session)) where sessions[id]!.count > Self.maxPerSession {
                sessions[id]!.removeFirst(sessions[id]!.count - Self.maxPerSession)
            }
            // Sessões sem nada recente saem da memória.
            sessions = sessions.filter { ($0.value.last?.timestamp ?? .distantPast) >= cutoff }
        }
    }

    func signals(for sessions: Set<String>) -> [String: [SessionSignal]] {
        storage.withLock { stored in stored.filter { sessions.contains($0.key) } }
    }
}
