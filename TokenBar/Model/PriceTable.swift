import Foundation

struct ModelPrice: Codable, Sendable, Equatable {
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

/// De onde veio a tabela de preços em uso.
enum PriceSource: Equatable, Sendable {
    case user        // prices.json do usuário (sempre vence)
    case remote      // baixada do repositório e guardada em cache
    case bundled     // embutida no app
}

/// Tabela de preços por modelo. Ordem: `prices.json` do usuário; senão, a mais recente (`asOf`)
/// entre a baixada do repositório e a embutida no app.
struct PriceTable: Codable, Sendable, Equatable {
    let asOf: String
    let cacheWrite5mMultiplier: Double
    let cacheWrite1hMultiplier: Double
    let models: [ModelPrice]

    static var userOverrideURL: URL { Persistence.directory.appending(path: "prices.json") }
    static var remoteCacheURL: URL { Persistence.directory.appending(path: "prices-remote.json") }
    static var bundledURL: URL? { Bundle.main.url(forResource: "prices", withExtension: "json") }

    static let empty = PriceTable(asOf: "-", cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2, models: [])

    static func load() -> PriceTable { loadWithSource().table }

    static func loadWithSource() -> (table: PriceTable, source: PriceSource) {
        select(user: read(userOverrideURL), remote: read(remoteCacheURL), bundled: bundledURL.flatMap(read))
    }

    /// Regra de escolha, separada para ser testável.
    static func select(user: PriceTable?, remote: PriceTable?, bundled: PriceTable?) -> (table: PriceTable, source: PriceSource) {
        if let user { return (user, .user) }
        if let remote, remote.asOf > (bundled?.asOf ?? "") { return (remote, .remote) }
        if let bundled { return (bundled, .bundled) }
        if let remote { return (remote, .remote) }
        return (empty, .bundled)
    }

    static func read(_ url: URL) -> PriceTable? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PriceTable.self, from: data)
    }

    /// Checagem de sanidade antes de aceitar uma tabela baixada da rede.
    var isValid: Bool {
        guard !models.isEmpty, asOf.count >= 10,
              (1...3).contains(cacheWrite5mMultiplier), (1...4).contains(cacheWrite1hMultiplier) else { return false }
        return models.allSatisfy { price in
            !price.match.isEmpty && price.input >= 0 && price.output >= 0 && price.cacheRead >= 0
                && price.input < 1_000 && price.output < 1_000 && price.cacheRead < 1_000
        }
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
