#if DEBUG
import Foundation
import SwiftData

/// Dados fictícios só para validar a UI e o banco durante o desenvolvimento (antes dos coletores reais do M1).
@MainActor
enum SampleData {
    private struct SampleModel {
        let provider: Provider
        let name: String
        let inputPerMTok: Double   // US$ por milhão de tokens — valores ilustrativos
        let outputPerMTok: Double
    }

    private static let models: [SampleModel] = [
        .init(provider: .anthropic, name: "claude-opus-5-5", inputPerMTok: 5, outputPerMTok: 25),
        .init(provider: .anthropic, name: "claude-sonnet-5", inputPerMTok: 3, outputPerMTok: 15),
        .init(provider: .anthropic, name: "claude-haiku-4-5", inputPerMTok: 1, outputPerMTok: 5),
        .init(provider: .openai, name: "gpt-5", inputPerMTok: 1.25, outputPerMTok: 10),
        .init(provider: .google, name: "gemini-2.5-pro", inputPerMTok: 1.25, outputPerMTok: 10),
        .init(provider: .local, name: "llama3.1:8b", inputPerMTok: 0, outputPerMTok: 0),
    ]

    static func insert(into context: ModelContext, days: Int = 8) {
        let now = Date.now
        for _ in 0..<(days * 40) {
            let model = models.randomElement()!
            let input = Int.random(in: 500...40_000)
            let output = Int.random(in: 100...6_000)
            let cacheRead = Bool.random() ? Int.random(in: 0...60_000) : 0
            let cost = (Double(input) * model.inputPerMTok
                        + Double(output) * model.outputPerMTok
                        + Double(cacheRead) * model.inputPerMTok * 0.1) / 1_000_000
            context.insert(UsageEvent(
                timestamp: now.addingTimeInterval(-Double.random(in: 0...(Double(days) * 86_400))),
                provider: model.provider,
                model: model.name,
                project: ["TokenBar", "meet-in-between", "portfolio"].randomElement(),
                tool: ["Claude Code", "API", "Codex CLI"].randomElement(),
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                costUSD: cost
            ))
        }
        try? context.save()
    }

    /// Apaga só os dados de exemplo (ids `local:`), preservando o que veio dos coletores.
    static func deleteAll(in context: ModelContext) {
        try? context.delete(model: UsageEvent.self, where: #Predicate { $0.externalID.starts(with: "local:") })
        try? context.save()
    }
}
#endif
