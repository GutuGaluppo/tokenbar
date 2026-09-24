import Foundation
import SwiftData

/// Grava eventos no banco fora da main thread. Como `externalID` é único, reinserir o mesmo
/// evento atualiza o registro (upsert) — a versão mais recente de uma resposta prevalece.
@ModelActor
actor UsageIngestor {
    @discardableResult
    func upsert(_ items: [ParsedUsage]) throws -> Int {
        // Dentro do lote, a última ocorrência de cada id vence.
        var latest: [String: ParsedUsage] = [:]
        for item in items { latest[item.externalID] = item }

        for item in latest.values {
            modelContext.insert(UsageEvent(
                externalID: item.externalID,
                timestamp: item.timestamp,
                provider: item.provider,
                model: item.model,
                project: item.project,
                tool: item.tool,
                session: item.session,
                inputTokens: item.tokens.input,
                outputTokens: item.tokens.output,
                cacheWriteTokens: item.tokens.cacheWrite,
                cacheReadTokens: item.tokens.cacheRead,
                costUSD: item.costUSD.isNaN ? 0 : item.costUSD
            ))
        }
        try modelContext.save()
        return latest.count
    }

    func count(externalIDPrefix prefix: String) -> Int {
        let descriptor = FetchDescriptor<UsageEvent>(predicate: #Predicate { $0.externalID.starts(with: prefix) })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    func deleteAll(externalIDPrefix prefix: String) throws {
        try modelContext.delete(model: UsageEvent.self, where: #Predicate { $0.externalID.starts(with: prefix) })
        try modelContext.save()
    }
}
