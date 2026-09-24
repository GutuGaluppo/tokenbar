import Foundation
import SwiftData

/// Um evento normalizado de consumo, vindo de qualquer provedor ou ferramenta.
@Model
final class UsageEvent {
    #Index<UsageEvent>([\.timestamp], [\.providerRaw, \.timestamp])

    /// Identificador estável na origem (ex.: `cc:<message.id>:<requestId>`). Único: inserir de novo
    /// o mesmo evento atualiza o registro existente em vez de duplicar.
    @Attribute(.unique) var externalID: String
    var timestamp: Date
    var providerRaw: String
    var model: String
    var project: String?
    var tool: String?
    var session: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheWriteTokens: Int
    var cacheReadTokens: Int
    var costUSD: Double

    init(
        externalID: String = "local:\(UUID().uuidString)",
        timestamp: Date,
        provider: Provider,
        model: String,
        project: String? = nil,
        tool: String? = nil,
        session: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheWriteTokens: Int = 0,
        cacheReadTokens: Int = 0,
        costUSD: Double
    ) {
        self.externalID = externalID
        self.timestamp = timestamp
        self.providerRaw = provider.rawValue
        self.model = model
        self.project = project
        self.tool = tool
        self.session = session
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.costUSD = costUSD
    }

    var provider: Provider { Provider(rawValue: providerRaw) ?? .other }

    var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }
}
