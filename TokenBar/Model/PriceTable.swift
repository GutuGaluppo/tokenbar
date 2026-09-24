import Foundation

struct ModelPrice: Codable, Sendable {
    let match: String
    let provider: Provider
    let input: Double       // US$ / 1M tokens
    let output: Double
    let cacheRead: Double
    let fastMultiplier: Double?
}

struct TokenCounts: Sendable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
}

/// Tabela de preços por modelo. Usa o JSON do bundle, ou o do usuário em
/// `~/Library/Application Support/TokenBar/prices.json` quando existir.
struct PriceTable: Codable, Sendable {
    let asOf: String
    let cacheWrite5mMultiplier: Double
    let cacheWrite1hMultiplier: Double
    let models: [ModelPrice]

    static var userOverrideURL: URL { Persistence.directory.appending(path: "prices.json") }

    static func load() -> PriceTable {
        let candidates = [userOverrideURL, Bundle.main.url(forResource: "prices", withExtension: "json")].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let table = try? JSONDecoder().decode(PriceTable.self, from: data) {
                return table
            }
        }
        return PriceTable(asOf: "-", cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2, models: [])
    }

    /// Casa pelo prefixo mais longo, então `claude-opus-5-5` não cai em `claude-opus-5`.
    func price(for model: String) -> ModelPrice? {
        models
            .filter { model.hasPrefix($0.match) }
            .max { $0.match.count < $1.match.count }
    }

    /// Custo em US$, ou nil quando o modelo não está na tabela.
    func cost(model: String, tokens: TokenCounts, fast: Bool = false) -> Double? {
        guard let price = price(for: model) else { return nil }
        let multiplier = fast ? (price.fastMultiplier ?? 1) : 1
        let dollars = Double(tokens.input) * price.input
            + Double(tokens.output) * price.output
            + Double(tokens.cacheWrite5m) * price.input * cacheWrite5mMultiplier
            + Double(tokens.cacheWrite1h) * price.input * cacheWrite1hMultiplier
            + Double(tokens.cacheRead) * price.cacheRead
        return dollars * multiplier / 1_000_000
    }
}
