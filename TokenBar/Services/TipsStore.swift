import Foundation
import SwiftData
import Observation
import os

/// Roda o motor de dicas sobre os últimos 14 dias e guarda o que o usuário ignorou.
@MainActor
@Observable
final class TipsStore {
    private(set) var tips: [Tip] = []
    private(set) var dismissed: [Tip] = []
    /// Dicas marcadas como aplicadas e o resultado medido de cada uma.
    private(set) var realized: [RealizedSaving] = []

    /// Economia realizada somada de todas as dicas aplicadas (US$ desde cada aplicação).
    var realizedTotal: Double {
        realized.reduce(0) { total, item in
            if case .saved(let value, _, _) = item.status { return total + value }
            return total
        }
    }
    private(set) var lastRun: Date?

    /// A dica em destaque no popover: no máximo uma nova por dia, para não virar ruído.
    var featured: Tip? {
        if let id = featuredID, let tip = tips.first(where: { $0.id == id }) { return tip }
        return tips.first
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let store: UsageStore
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    private var featuredID: String?

    private static let log = Logger(subsystem: "dev.galuppo.TokenBar", category: "Tips")
    private static let dismissedKey = "tips.dismissedUntil"
    private static let featuredKey = "tips.featured"
    private static let appliedKey = "tips.applied"
    private static let dismissDuration: TimeInterval = 30 * 86_400

    init(container: ModelContainer, store: UsageStore) {
        self.container = container
        self.store = store
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRun() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        }
        run()
    }

    func dismiss(_ tip: Tip) {
        var until = dismissedUntil
        until[tip.id] = Date.now.addingTimeInterval(Self.dismissDuration)
        UserDefaults.standard.set(until, forKey: Self.dismissedKey)
        run()
    }

    func markApplied(_ tip: Tip) {
        var list = applied.filter { $0.id != tip.id }
        list.append(AppliedTip(id: tip.id, title: tip.title, appliedAt: .now))
        saveApplied(list)
        run()
    }

    func undoApplied(_ item: AppliedTip) {
        saveApplied(applied.filter { $0.id != item.id })
        run()
    }

    private var applied: [AppliedTip] {
        guard let data = UserDefaults.standard.data(forKey: Self.appliedKey) else { return [] }
        return (try? JSONDecoder().decode([AppliedTip].self, from: data)) ?? []
    }

    private func saveApplied(_ list: [AppliedTip]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.appliedKey)
    }

    func restore(_ tip: Tip) {
        var until = dismissedUntil
        until.removeValue(forKey: tip.id)
        UserDefaults.standard.set(until, forKey: Self.dismissedKey)
        run()
    }

    private var dismissedUntil: [String: Date] {
        (UserDefaults.standard.dictionary(forKey: Self.dismissedKey) as? [String: Date] ?? [:])
            .filter { $0.value > .now }
    }

    private func scheduleRun() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            run()
        }
    }

    func run() {
        let now = Date.now
        let applied = self.applied
        let window = now.addingTimeInterval(-Double(TipsEngine.windowDays) * 86_400)
        // Para medir o antes/depois, busca também os 14 dias anteriores à aplicação mais antiga.
        let earliestApplied = applied.map(\.appliedAt).min() ?? now
        let since = min(window, earliestApplied.addingTimeInterval(-RealizedSaving.baselineDays * 86_400))
        let descriptor = FetchDescriptor<UsageEvent>(predicate: #Predicate { $0.timestamp >= since })
        let allEvents = ((try? container.mainContext.fetch(descriptor)) ?? []).map {
            TipInput(externalID: $0.externalID, timestamp: $0.timestamp, model: $0.model, tool: $0.tool,
                     session: $0.session, input: $0.inputTokens, output: $0.outputTokens,
                     cacheWrite: $0.cacheWriteTokens, cacheRead: $0.cacheReadTokens, costUSD: $0.costUSD)
        }
        let events = allEvents.filter { $0.timestamp >= window }
        let engine = TipsEngine(prices: .load())
        realized = applied.sorted { $0.appliedAt > $1.appliedAt }
            .map { RealizedSaving.evaluate($0, engine: engine, events: allEvents, now: now) }

        let all = engine.tips(
            for: events, budgets: .load(), monthCostUSD: store.monthCostUSD
        )
        let hidden = dismissedUntil
        let appliedIDs = Set(applied.map(\.id))
        // Aplicadas saem das sugestões: passam a ser acompanhadas em "Aplicadas".
        tips = all.filter { hidden[$0.id] == nil && !appliedIDs.contains($0.id) }
        dismissed = all.filter { hidden[$0.id] != nil && !appliedIDs.contains($0.id) }
        lastRun = .now
        updateFeatured()
        #if DEBUG
        for item in realized {
            Self.log.notice("aplicada \(item.id, privacy: .public): \(String(describing: item.status), privacy: .public)")
        }
        for tip in all {
            Self.log.notice("dica \(tip.id, privacy: .public): \(tip.savingsText ?? "aviso", privacy: .public) — \(tip.evidence, privacy: .public)")
        }
        #endif
    }

    /// Mantém a mesma dica em destaque durante o dia; troca no dia seguinte ou se ela sumir.
    private func updateFeatured() {
        let today = Calendar.current.startOfDay(for: .now)
        let saved = UserDefaults.standard.dictionary(forKey: Self.featuredKey)
        if let id = saved?["id"] as? String, let day = saved?["day"] as? Date, day == today,
           tips.contains(where: { $0.id == id }) {
            featuredID = id
            return
        }
        featuredID = tips.first?.id
        if let id = featuredID {
            UserDefaults.standard.set(["id": id, "day": today], forKey: Self.featuredKey)
        }
    }
}
