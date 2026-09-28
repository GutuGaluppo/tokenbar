import Foundation

/// Economia das dicas ao vivo: quando a conversa encolhe (compactação) depois de uma dica de contexto,
/// cada chamada seguinte deixa de reler do cache os tokens que saíram. Estimativa conservadora: cada
/// queda conta só até a próxima.
enum LiveSavings {
    /// Dicas que pedem para compactar.
    static let contextTipIDs: Set<String> = ["context-large", "context-full", "plan-session", "daily-budget"]
    /// Queda mínima do contexto, entre duas chamadas seguidas, para contar como compactação.
    static let minimumDrop = 0.4
    static let minimumContext = LiveSessionsEngine.cacheContext

    /// Economia em US$ nas chamadas da conversa principal (`main`, em ordem) desde que a dica apareceu.
    static func saved(main: [LiveInput], tipShownAt: Date, prices: PriceTable) -> Double {
        var saved = 0.0
        var dropped = 0
        for (previous, current) in zip(main, main.dropFirst()) {
            if current.timestamp >= tipShownAt, previous.context >= minimumContext,
               Double(current.context) <= Double(previous.context) * (1 - minimumDrop) {
                dropped = previous.context - current.context
            }
            guard dropped > 0, let price = prices.price(for: current.model) else { continue }
            saved += Double(dropped) * price.cacheRead / 1_000_000
        }
        return saved
    }
}

/// Economia por sessão, guardada para somar os últimos 30 dias mesmo depois que a sessão termina.
struct LiveSavingsLedger {
    struct Entry: Codable, Equatable {
        var savedUSD: Double
        var updatedAt: Date
    }

    static let key = "liveTips.savings"
    static let window: TimeInterval = 30 * 86_400

    private(set) var entries: [String: Entry]

    init(entries: [String: Entry] = [:]) { self.entries = entries }

    static func load() -> LiveSavingsLedger {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return LiveSavingsLedger() }
        return LiveSavingsLedger(entries: entries)
    }

    func save() {
        guard !AppEnvironment.isIsolated, let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// A economia de uma sessão só cresce; sessões com mais de 30 dias saem.
    mutating func update(session: String, savedUSD: Double, now: Date) -> Bool {
        let before = entries
        entries = entries.filter { now.timeIntervalSince($0.value.updatedAt) <= Self.window }
        if savedUSD > (entries[session]?.savedUSD ?? 0) + 0.000_1 {
            entries[session] = Entry(savedUSD: savedUSD, updatedAt: now)
        }
        return entries != before
    }

    var total: Double { entries.values.reduce(0) { $0 + $1.savedUSD } }
}
