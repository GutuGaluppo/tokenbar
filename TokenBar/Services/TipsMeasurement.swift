import Foundation

/// Desperdício que uma dica ataca, normalizado por atividade: comparar "por unidade" antes e
/// depois de aplicar separa o efeito da dica de variações no volume de uso.
struct TipMeasurement {
    /// US$ que a dica evitaria.
    let waste: Double
    /// Quantidade de atividade no mesmo recorte (respostas, sessões, mil tokens…).
    let units: Double

    var rate: Double { units > 0 ? waste / units : 0 }
}

extension TipsEngine {
    /// Dicas cujo efeito dá para medir (avisos, como o ritmo do mês, não entram).
    static let measurableTipIDs: Set<String> = [
        "opus5-to-opus55", "opus-short-steps", "long-context", "heavy-session-start",
        "api-caching", "api-batch", "long-outputs",
    ]

    func measure(_ tipID: String, events: [TipInput]) -> TipMeasurement? {
        switch tipID {
        case "opus5-to-opus55":
            // Unidade: respostas no Opus (5 ou 5.5). Depois de trocar, o custo extra do 5 some.
            let opus = events.filter { isOpus($0.model) }
            let waste = opus.filter { isOpus5($0.model) }
                .reduce(0) { $0 + ($1.costUSD - (repriced($1, to: "claude-opus-5-5") ?? $1.costUSD)) }
            return TipMeasurement(waste: waste, units: Double(opus.count))

        case "opus-short-steps":
            // Unidade: respostas curtas em qualquer modelo Claude; desperdício = as que ficaram no Opus.
            let short = events.filter { $0.model.hasPrefix("claude-") && $0.output < 1_000 && $0.costUSD > 0 }
            let waste = short.filter { isOpus($0.model) }
                .reduce(0) { $0 + ($1.costUSD - (repriced($1, to: "claude-sonnet-5") ?? $1.costUSD)) }
            return TipMeasurement(waste: waste, units: Double(short.count))

        case "long-context":
            let claudeCode = events.filter(\.isClaudeCode)
            let waste = claudeCode.reduce(0.0) { total, event in
                guard event.context > 100_000 else { return total }
                let contextCost = max(event.costUSD - outputCost(event), 0)
                return total + contextCost * Double(event.context - 100_000) / Double(event.context)
            }
            return TipMeasurement(waste: waste, units: Double(claudeCode.count))

        case "heavy-session-start":
            let sessions = Dictionary(grouping: events.filter { $0.isClaudeCode && $0.session != nil }, by: { $0.session! })
            var waste = 0.0
            for (_, sessionEvents) in sessions {
                guard let first = sessionEvents.min(by: { $0.timestamp < $1.timestamp }),
                      first.context > 25_000, let price = prices.price(for: first.model) else { continue }
                let excess = Double(first.context - 25_000)
                waste += excess * (price.input * prices.cacheWrite1hMultiplier + Double(sessionEvents.count) * price.cacheRead) / 1_000_000
            }
            return TipMeasurement(waste: waste, units: Double(sessions.count))

        case "api-caching":
            // Unidade: mil tokens de entrada na API; desperdício = entrada paga sem cache.
            let api = events.filter(\.isAnthropicAPI)
            let waste = api.reduce(0.0) { total, event in
                guard let price = prices.price(for: event.model) else { return total }
                return total + Double(event.input) * price.input * 0.9 / 1_000_000
            }
            let tokens = api.reduce(0) { $0 + $1.input + $1.cacheRead }
            return TipMeasurement(waste: waste, units: Double(tokens) / 1_000)

        case "api-batch":
            // Desperdício = metade do custo fora do batch (o desconto não aproveitado).
            let api = events.filter(\.isAnthropicAPI)
            let waste = api.filter { $0.tool?.contains("batch") != true }.reduce(0) { $0 + $1.costUSD * 0.5 }
            let tokens = api.reduce(0) { $0 + $1.input + $1.output + $1.cacheWrite + $1.cacheRead }
            return TipMeasurement(waste: waste, units: Double(tokens) / 1_000)

        case "long-outputs":
            let waste = events.reduce(0.0) { total, event in
                guard event.output > 8_000, let price = prices.price(for: event.model) else { return total }
                return total + Double(event.output - 8_000) * price.output / 1_000_000
            }
            return TipMeasurement(waste: waste, units: Double(events.count))

        default:
            return nil
        }
    }
}

/// Uma dica que o usuário marcou como aplicada e o resultado medido desde então.
struct AppliedTip: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let appliedAt: Date
}

struct RealizedSaving: Identifiable, Equatable {
    enum Status: Equatable {
        /// Ainda sem dias suficientes depois de aplicar.
        case measuring(until: Date)
        /// Sem atividade suficiente (antes ou depois) para comparar.
        case insufficientData
        /// Desperdício por unidade caiu: economia em US$ desde a aplicação e projeção mensal.
        case saved(total: Double, monthly: Double, reduction: Double)
        /// Desperdício por unidade não caiu (ou subiu).
        case noSavings(change: Double)
        case notMeasurable
    }

    let tip: AppliedTip
    let status: Status

    var id: String { tip.id }

    static let minimumDays = 2.0
    static let baselineDays = 14.0

    static func evaluate(_ tip: AppliedTip, engine: TipsEngine, events: [TipInput], now: Date = .now) -> RealizedSaving {
        guard TipsEngine.measurableTipIDs.contains(tip.id) else { return .init(tip: tip, status: .notMeasurable) }
        let days = now.timeIntervalSince(tip.appliedAt) / 86_400
        guard days >= minimumDays else {
            return .init(tip: tip, status: .measuring(until: tip.appliedAt.addingTimeInterval(minimumDays * 86_400)))
        }
        let baselineStart = tip.appliedAt.addingTimeInterval(-baselineDays * 86_400)
        let before = events.filter { $0.timestamp >= baselineStart && $0.timestamp < tip.appliedAt }
        let after = events.filter { $0.timestamp >= tip.appliedAt }
        guard let b = engine.measure(tip.id, events: before), let a = engine.measure(tip.id, events: after),
              b.units > 0, a.units > 0, b.waste > 0
        else { return .init(tip: tip, status: .insufficientData) }

        let reduction = 1 - a.rate / b.rate
        guard reduction > 0 else { return .init(tip: tip, status: .noSavings(change: a.rate / b.rate - 1)) }
        let total = (b.rate - a.rate) * a.units
        return .init(tip: tip, status: .saved(total: total, monthly: total / days * 30, reduction: reduction))
    }
}
